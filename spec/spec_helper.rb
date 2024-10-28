$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))

# only load pry for MRI > 1.8
begin
  require 'pry' if RUBY_ENGINE == 'ruby'
rescue StandardError
  nil
end
require 'popen4'
require 'rspec'
require 'rspec/mocks/standalone'
require 'set'
require 'puma'

require 'librato/metrics'

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.default_formatter = :documentation
  # purge all metrics from test account
  def delete_all_metrics
    connection = Librato::Metrics.client.connection
    Librato::Metrics.metrics.each do |metric|
      # puts "deleting #{metric['name']}..."
      # expects 204
      connection.delete("metrics/#{metric['name']}")
    end
  end

  # purge all annotations from test account
  def delete_all_annotations
    annotator = Librato::Metrics::Annotator.new
    streams = annotator.list
    return unless streams['annotations']

    names = streams['annotations'].map { |s| s['name'] }
    names.each { |name| annotator.delete name }
  end

  # set up test account credentials for integration tests
  def prep_integration_tests
    SpecServer.start
    SpecServer.reset

    test_api_user = ENV['TEST_API_USER'] || 'example@test.com'
    test_api_key = ENV['TEST_API_KEY'] || 'test-api-key-zomg'

    Librato::Metrics.api_endpoint = "http://localhost:#{SpecServer.port}"
    Librato::Metrics.authenticate test_api_key, test_api_user
  end

  def rackup_path(*parts)
    File.expand_path(File.join(File.dirname(__FILE__), 'rackups', *parts))
  end

  # fire up a given rackup file for the enclosed tests
  def with_rackup(name)
    if RUBY_PLATFORM == 'java'
      pid, w, r, e = IO.popen4('rackup', rackup_path(name), '-p 9296')
    else
      GC.disable
      pid, w, r, e = Open4.popen4('rackup', rackup_path(name), '-p 9296')
    end
    until e.gets =~ /HTTPServer#start:/; end
    yield
  ensure
    Process.kill(9, pid)
    if RUBY_PLATFORM != 'java'
      GC.enable
      Process.wait(pid)
    end
  end
end

# Ex: 'foobar'.should start_with('foo') #=> true
#
RSpec::Matchers.define :start_with do |start_string|
  match do |string|
    start_length = start_string.length
    string[0..start_length - 1] == start_string
  end
end

# Compares hashes of arrays by converting the arrays to
# sets before comparision
#
# @example
#   {:foo => [1,3,2]}.should equal_unordered({:foo => [1,2,3]})
RSpec::Matchers.define :equal_unordered do |result|
  result.each do |key, value|
    result[key] = value.to_set if value.respond_to?(:to_set)
  end
  match do |target|
    target.each do |key, value|
      target[key] = value.to_set if value.respond_to?(:to_set)
    end
    target == result
  end
end

class SpecServer
  LOCK = Mutex.new
  COND = ConditionVariable.new

  class << self
    attr_reader :port

    def started?
      !!@started
    end

    def start(opts = {})
      if @started
        if opts[:Port] && opts[:Port] != port
          raise "requested server start with port #{opts[:Port]}, but a server is already running on #{port}"
        end

        return
      end

      LOCK.synchronize do
        return if @started

        @started = true
        @server = Puma::Server.new(self)
        listener = @server.add_tcp_listener('127.0.0.1', opts[:Port])
        _, @port, = listener.addr

        @server_thread = @server.run
      end
    end

    def status
      @server_thread&.status
    end

    def wait(opts = {})
      timeout = opts[:timeout] || EMBEDDED_HTTP_SERVER_TIMEOUT
      timeout_at = monotonic_time + timeout
      count = opts[:count] || 1
      filter = ->(r) { opts[:resource] ? r['PATH_INFO'] == opts[:resource] : true }

      LOCK.synchronize do
        loop do
          return true if filter_requests(opts).count(&filter) >= count

          ttl = timeout_at - monotonic_time

          if ttl <= 0
            puts '***TIMEOUT***'
            puts "timeout: #{timeout}"
            puts "seeking auth: #{opts[:authentication]}"
            puts 'requests:'
            @requests.each do |request|
              puts "[auth: #{request['HTTP_AUTHORIZATION']}] #{Rack::Request.new(request).url}: " \
                      "#{!!filter.call(request)}"
            end
            puts '*************'
            raise "Server.wait timeout: got #{filter_requests(opts).count(&filter)} not #{count}"
          end

          COND.wait(LOCK, ttl)
        end
      end
    end

    def reset
      LOCK.synchronize do
        @requests = []
        @mocks = []
      end
    end

    def mock(path = nil, method = nil, &blk)
      LOCK.synchronize { @mocks << { path: path, method: method, blk: blk } }
    end

    def requests(opts = {})
      LOCK.synchronize { filter_requests(opts) }
    end

    def reports(opts = {})
      requests(opts)
        .select { |env| env['PATH_INFO'] == '/report' }
        .map { |env| SpecHelper::Messages::Batch.decode(env['rack.input'].dup) }
    end

    def call(env)
      trace '%s http://%s:%s%s', env['REQUEST_METHOD'], env['SERVER_NAME'], env['SERVER_PORT'], env['PATH_INFO']

      ret = handle(env)

      trace '  -> %s', ret[0]
      trace '  -> %s', ret[2].join("\n")

      ret
    end

    private

    def handle(env)
      if (input = env.delete('rack.input'))
        str = input.read.dup
        str.freeze

        str = JSON.parse(str) if env['CONTENT_TYPE'] == 'application/json'

        env['rack.input'] = str
      end

      json = ['application/json', 'application/json; charset=UTF-8'].sample

      LOCK.synchronize do
        @requests << env
        COND.broadcast

        mock =
          @mocks.find do |m|
            (!m[:path] || m[:path] == env['PATH_INFO']) &&
              (!m[:method] || m[:method].to_s.upcase == env['REQUEST_METHOD'])
          end

        if mock
          @mocks.delete(mock)

          ret =
            begin
              mock[:blk].call(env)
            rescue StandardError => e
              trace "#{e.inspect}\n#{e.backtrace.map { |l| "  #{l}" }.join("\n")}"
              [500, { 'content-type' => 'text/plain', 'content-length' => '4' }, ['Fail']]
            end

          if ret.is_a?(Array)
            return ret if ret.length == 3

            body = ret.last
            body = body.to_json if body.is_a?(Hash)

            return ret[0], { 'content-type' => json, 'content-length' => body.bytesize.to_s }, [body]
          elsif respond_to?(:to_str)
            return 200, { 'content-type' => 'text/plain', 'content-length' => ret.bytesize.to_s }, [ret]
          else
            ret = ret.to_json
            return 200, { 'content-type' => json, 'content-length' => ret.bytesize.to_s }, [ret]
          end
        end
      end

      [200, { 'content-type' => 'text/plain', 'content-length' => '7' }, ['Thanks!']]
    end

    def trace(line, *args)
      printf("[HTTP Server] #{line}\n", *args) if ENV['SKYLIGHT_ENABLE_TRACE_LOGS']
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def filter_requests(opts = {})
      @requests.select do |x|
        opts[:authentication] ? x['HTTP_AUTHORIZATION'].start_with?(opts[:authentication]) : true
      end
    end
  end
end
