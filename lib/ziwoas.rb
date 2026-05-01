require "logger"
require "tzinfo"
require "config_loader"
require "shelly_client"
require "fritz_dect_client"
require "poller"
require "aggregator"
require "ziwoas/scheduler"
require "ziwoas/signal_handler"

module Ziwoas
  class App
    attr_reader :config, :logger, :poller, :aggregator

    def self.boot(config_path: ENV.fetch("CONFIG_PATH"))
      new(config_path).tap(&:start_threads!)
    end

    def initialize(config_path)
      @logger = Logger.new($stdout)
      @logger.level = Logger::INFO
      @config = ConfigLoader.load(config_path)
    end

    def start_threads!
      tz = TZInfo::Timezone.get(@config.timezone)

      shelly_client = ShellyClient.new(timeout: @config.poll.timeout_seconds)
      fritz_client  = if @config.fritz_box
                        FritzDectClient.new(
                          host:     @config.fritz_box.host,
                          user:     @config.fritz_box.user,
                          password: @config.fritz_box.password,
                          timeout:  @config.poll.timeout_seconds,
                        )
                      end
      clients = @config.plugs.to_h do |plug|
        [plug.id, plug.driver == :fritz_dect ? fritz_client : shelly_client]
      end

      @poller = Poller.new(
        plugs:        @config.plugs,
        clients:      clients,
        logger:       @logger,
        breaker_opts: {
          threshold:     @config.poll.circuit_breaker_threshold,
          probe_seconds: @config.poll.circuit_breaker_probe_seconds,
        },
      )
      @aggregator = Aggregator.new(
        timezone:           tz,
        raw_retention_days: @config.aggregator.raw_retention_days,
      )
      @scheduler = Scheduler.new(
        aggregator: @aggregator,
        run_at:     @config.aggregator.run_at,
        timezone:   tz,
        logger:     @logger,
        backup_dir: Rails.root.join("storage", "backup").to_s,
      )

      @poller_thread     = spawn_thread("poller")     { @poller.run(@config.poll.interval_seconds) }
      @aggregator_thread = spawn_thread("aggregator") { @scheduler.run }

      SignalHandler.install(self) unless defined?(Puma)
    end

    def stop!
      @logger.info("ziwoas: shutting down")
      @poller&.stop!
      @scheduler&.stop!
      [@poller_thread, @aggregator_thread].each { |t| t&.join(3) }
    end

    private

    def spawn_thread(name)
      Thread.new do
        Thread.current.name = name
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = true
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            yield
          rescue => e
            @logger.error("thread #{name} crashed: #{e.class}: #{e.message}")
            @logger.error(e.backtrace.first(10).join("\n"))
            Process.kill("TERM", Process.pid)
          end
        end
      end
    end
  end
end
