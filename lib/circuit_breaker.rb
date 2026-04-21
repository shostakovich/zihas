class CircuitBreaker
  attr_reader :state

  def initialize(threshold:, probe_seconds:, clock: -> { Time.now.to_f }, &on_change)
    @threshold      = threshold
    @probe_seconds  = probe_seconds
    @clock          = clock
    @on_change      = on_change
    @state          = :closed
    @failure_count  = 0
    @open_until     = 0
  end

  # True if the caller should skip the next operation this tick.
  def skip?
    @state == :open && @clock.call < @open_until
  end

  def record_success
    transition(:closed) if @state == :open
    @failure_count = 0
  end

  def record_failure
    @failure_count += 1

    if @state == :open
      @open_until = @clock.call + @probe_seconds
    elsif @failure_count >= @threshold
      transition(:open)
      @open_until = @clock.call + @probe_seconds
    end
  end

  private

  def transition(new_state)
    from = @state
    return if from == new_state
    @state = new_state
    @on_change&.call(from, new_state)
  end
end
