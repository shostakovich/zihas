require "test_helper"

class DailyEnergySummaryTest < ActiveSupport::TestCase
  setup { DailyEnergySummary.delete_all }

  test "persists with date as primary key" do
    DailyEnergySummary.create!(
      date: "2026-04-10",
      produced_wh: 1000.0,
      consumed_wh: 600.0,
      self_consumed_wh: 400.0
    )

    row = DailyEnergySummary.find("2026-04-10")
    assert_in_delta 1000.0, row.produced_wh
    assert_in_delta 600.0,  row.consumed_wh
    assert_in_delta 400.0,  row.self_consumed_wh
  end

  test "validates required fields" do
    record = DailyEnergySummary.new
    assert_not record.valid?
    assert record.errors[:date].any?
  end
end
