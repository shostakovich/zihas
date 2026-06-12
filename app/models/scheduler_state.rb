class SchedulerState < ApplicationRecord
  # Single-row table: the schedule tick watermark.
  def self.last_tick_at
    first&.last_tick_at
  end

  def self.advance!(time, expected: nil)
    row = first
    return new(last_tick_at: time).save! if row.nil?
    return row.update!(last_tick_at: time) if expected.nil?

    where(id: row.id, last_tick_at: expected).update_all(last_tick_at: time, updated_at: Time.current) == 1
  end
end
