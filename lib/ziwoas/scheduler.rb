module Ziwoas
  class Scheduler
    def initialize(aggregator:, run_at:, timezone:, logger:, backup_dir:)
      @aggregator = aggregator
      @run_at     = run_at
      @tz         = timezone
      @logger     = logger
      @backup_dir = backup_dir
      @stopping   = false
    end

    def run
      until @stopping
        sleep_until_run_at
        break if @stopping
        perform_run
      end
    end

    def stop!
      @stopping = true
    end

    private

    # Runs the nightly job, swallowing exceptions so that a transient failure
    # (DB error, disk full during VACUUM INTO, ...) doesn't kill the scheduler
    # thread and silently disable all future nights.
    def perform_run
      @logger.info("aggregator: starting nightly run")
      @aggregator.run_once
      @aggregator.backup!(@backup_dir)
      @logger.info("aggregator: done")
    rescue StandardError => e
      @logger.error("aggregator: nightly run failed: #{e.class}: #{e.message}")
      e.backtrace&.first(10)&.each { |line| @logger.error("  #{line}") }
    end

    def sleep_until_run_at
      hour, minute = @run_at.split(":").map(&:to_i)
      now_utc      = Time.now.utc
      local_now    = @tz.utc_to_local(now_utc)
      target_local = Time.new(local_now.year, local_now.month, local_now.day, hour, minute, 0)
      target_utc   = @tz.local_to_utc(target_local)
      target_utc  += 86_400 if target_utc <= now_utc
      sleep_for    = target_utc - now_utc

      while sleep_for > 0 && !@stopping
        chunk = [ sleep_for, 5 ].min
        sleep(chunk)
        sleep_for -= chunk
      end
    end
  end
end
