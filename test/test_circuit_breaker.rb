require "test_helper"
require "circuit_breaker"

class CircuitBreakerTest < Minitest::Test
  def setup
    @now = 1_000.0
    @breaker = CircuitBreaker.new(threshold: 3, probe_seconds: 30, clock: -> { @now })
  end

  def test_initial_state_is_closed
    assert_equal :closed, @breaker.state
    refute @breaker.skip?
  end

  def test_opens_after_threshold_failures
    3.times { @breaker.record_failure }
    assert_equal :open, @breaker.state
    assert @breaker.skip?
  end

  def test_stays_closed_below_threshold
    2.times { @breaker.record_failure }
    assert_equal :closed, @breaker.state
  end

  def test_success_resets_failure_counter
    2.times { @breaker.record_failure }
    @breaker.record_success
    2.times { @breaker.record_failure }
    assert_equal :closed, @breaker.state
  end

  def test_skip_false_once_probe_deadline_reached
    3.times { @breaker.record_failure }
    assert @breaker.skip?
    @now += 29.9
    assert @breaker.skip?
    @now += 0.2
    refute @breaker.skip?
  end

  def test_successful_probe_closes_breaker
    3.times { @breaker.record_failure }
    @now += 31
    @breaker.record_success
    assert_equal :closed, @breaker.state
    refute @breaker.skip?
  end

  def test_failed_probe_keeps_open_and_extends_deadline
    3.times { @breaker.record_failure }
    @now += 31
    refute @breaker.skip?            # allowed to probe now
    @breaker.record_failure          # probe fails
    assert @breaker.skip?            # skipping again
  end

  def test_transitions_yield_state_change
    changes = []
    breaker = CircuitBreaker.new(threshold: 2, probe_seconds: 10, clock: -> { @now }) do |from, to|
      changes << [ from, to ]
    end
    breaker.record_failure
    breaker.record_failure          # closed → open
    @now += 11
    breaker.record_success          # open → closed
    assert_equal [ [ :closed, :open ], [ :open, :closed ] ], changes
  end
end
