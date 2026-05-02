require "test_helper"

class DailyTotalTest < ActiveSupport::TestCase
  def valid_daily_total
    DailyTotal.new(plug_id: "bkw", date: "2026-04-10", energy_wh: 800.0)
  end

  test "valid daily_total is valid" do
    assert valid_daily_total.valid?
  end

  test "plug_id is required" do
    dt = valid_daily_total
    dt.plug_id = nil
    refute dt.valid?
  end

  test "date must be YYYY-MM-DD format" do
    dt = valid_daily_total
    dt.date = "10/04/2026"
    refute dt.valid?
    assert_includes dt.errors[:date], "must be YYYY-MM-DD"
  end

  test "date is required" do
    dt = valid_daily_total
    dt.date = nil
    refute dt.valid?
  end

  test "energy_wh is required" do
    dt = valid_daily_total
    dt.energy_wh = nil
    refute dt.valid?
  end
end
