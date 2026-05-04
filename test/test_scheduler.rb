require "test_helper"
require "logger"
require "stringio"
require "tzinfo"
require "ziwoas/scheduler"

class SchedulerTest < ActiveSupport::TestCase
  # Aggregator double that records invocations and can raise on demand.
  class FakeAggregator
    attr_reader :run_calls, :backup_calls

    def initialize(raise_on_run: [], raise_on_backup: [])
      @run_calls       = 0
      @backup_calls    = 0
      @raise_on_run    = raise_on_run
      @raise_on_backup = raise_on_backup
    end

    def run_once
      @run_calls += 1
      raise "boom" if @raise_on_run.include?(@run_calls)
    end

    def backup!(_dir)
      @backup_calls += 1
      raise "backup boom" if @raise_on_backup.include?(@backup_calls)
    end
  end

  # Scheduler subclass that skips real sleeping and stops after `iterations`
  # passes through the loop.
  class TestScheduler < Ziwoas::Scheduler
    def initialize(iterations:, **kwargs)
      super(**kwargs)
      @iterations = iterations
      @loops      = 0
    end

    private

    def sleep_until_run_at
      @loops += 1
      stop! if @loops >= @iterations
    end
  end

  def build_scheduler(aggregator:, iterations:, log_io: StringIO.new)
    TestScheduler.new(
      iterations: iterations,
      aggregator: aggregator,
      run_at:     "03:15",
      timezone:   TZInfo::Timezone.get("Europe/Berlin"),
      logger:     Logger.new(log_io),
      backup_dir: "/tmp/ziwoas-test-backup",
    )
  end

  test "exception in run_once does not kill the scheduler loop" do
    aggregator = FakeAggregator.new(raise_on_run: [ 1 ])
    log_io     = StringIO.new
    scheduler  = build_scheduler(aggregator: aggregator, iterations: 3, log_io: log_io)

    scheduler.run

    assert_equal 3, aggregator.run_calls, "scheduler should keep invoking run_once after a failure"
    assert_equal 2, aggregator.backup_calls, "backup! is skipped on the failing iteration only"
    assert_match(/nightly run failed/, log_io.string)
  end

  test "exception in backup! does not kill the scheduler loop" do
    aggregator = FakeAggregator.new(raise_on_backup: [ 2 ])
    log_io     = StringIO.new
    scheduler  = build_scheduler(aggregator: aggregator, iterations: 3, log_io: log_io)

    scheduler.run

    assert_equal 3, aggregator.run_calls
    assert_equal 3, aggregator.backup_calls
    assert_match(/nightly run failed/, log_io.string)
  end

  test "stop! short-circuits the sleep so run returns" do
    aggregator = FakeAggregator.new
    scheduler  = build_scheduler(aggregator: aggregator, iterations: 1)

    scheduler.run

    assert_equal 1, aggregator.run_calls
  end
end
