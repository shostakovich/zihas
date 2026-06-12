require "test_helper"

class SchedulerStateTest < ActiveSupport::TestCase
  setup { SchedulerState.delete_all }

  test "last_tick_at is nil without a row" do
    assert_nil SchedulerState.last_tick_at
  end

  test "advance! creates then updates a single row" do
    t1 = Time.zone.local(2026, 6, 15, 12, 0)
    t2 = Time.zone.local(2026, 6, 15, 12, 1)
    SchedulerState.advance!(t1)
    assert_equal t1, SchedulerState.last_tick_at
    SchedulerState.advance!(t2)
    assert_equal t2, SchedulerState.last_tick_at
    assert_equal 1, SchedulerState.count
  end
end
