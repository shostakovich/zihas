class SchedulerState < ApplicationRecord
  # Single-row table: the schedule tick watermark.
  def self.last_tick_at
    first&.last_tick_at
  end

  def self.advance!(time)
    (first || new).update!(last_tick_at: time)
  end
end
