require "logger"
require "tzinfo"
require "config_loader"
require "shelly_client"
require "fritz_dect_client"
require "poller"
require "aggregator"

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
        timezone: tz,
        raw_retention_days: @config.aggregator.raw_retention_days,
      )

      @poller_thread     = spawn_thread("poller")     { @poller.run(@config.poll.interval_seconds) }
      @aggregator_thread = spawn_thread("aggregator") { aggregator_loop(tz) }
      install_signal_traps!
    end

    def stop!
      @logger.info("ziwoas: shutting down")
      @poller&.stop!
      @stopping = true
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

    def aggregator_loop(tz)
      until @stopping
        sleep_until_run_at(tz, @config.aggregator.run_at)
        break if @stopping
        @logger.info("aggregator: starting nightly run")
        @aggregator.run_once
        @aggregator.backup!(Rails.root.join("storage", "backup").to_s)
        @logger.info("aggregator: done")
      end
    end

    def sleep_until_run_at(tz, run_at)
      hour, minute = run_at.split(":").map(&:to_i)
      now_utc      = Time.now.utc
      local_now    = tz.utc_to_local(now_utc)
      target_local = Time.new(local_now.year, local_now.month, local_now.day, hour, minute, 0)
      target_utc   = tz.local_to_utc(target_local)
      target_utc  += 86_400 if target_utc <= now_utc
      sleep_for    = target_utc - now_utc

      # Sleep in short bursts so SIGTERM is responsive.
      while sleep_for > 0 && !@stopping
        chunk = [sleep_for, 5].min
        sleep(chunk)
        sleep_for -= chunk
      end
    end

    def install_signal_traps!
      %w[INT TERM].each do |sig|
        Signal.trap(sig) { stop! }
      end
    end
  end
end
