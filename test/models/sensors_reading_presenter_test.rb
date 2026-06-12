require "test_helper"

class SensorsReadingPresenterTest < ActiveSupport::TestCase
  def reading(co2: nil, battery_pct: nil, taken_at: Time.current)
    SensorReading.new(device_id: "X", taken_at: taken_at,
                      temperature: 20.0, humidity: 40, co2: co2, battery_pct: battery_pct)
  end

  test "co2_level returns :good below the warn threshold" do
    p = Sensors::ReadingPresenter.new(reading(co2: 800))
    assert_equal :good, p.co2_level
  end

  test "co2_level returns :warn at and above 1000 ppm" do
    assert_equal :warn, Sensors::ReadingPresenter.new(reading(co2: 1000)).co2_level
    assert_equal :warn, Sensors::ReadingPresenter.new(reading(co2: 1399)).co2_level
  end

  test "co2_level returns :bad above 1400 ppm" do
    assert_equal :bad, Sensors::ReadingPresenter.new(reading(co2: 1401)).co2_level
  end

  test "co2_level returns nil when co2 is missing" do
    assert_nil Sensors::ReadingPresenter.new(reading(co2: nil)).co2_level
    assert_nil Sensors::ReadingPresenter.new(nil).co2_level
  end

  test "battery_low? is true at or below 20%" do
    assert Sensors::ReadingPresenter.new(reading(battery_pct: 20)).battery_low?
    assert Sensors::ReadingPresenter.new(reading(battery_pct: 5)).battery_low?
    refute Sensors::ReadingPresenter.new(reading(battery_pct: 21)).battery_low?
  end

  test "battery_low? is false when battery_pct is missing" do
    refute Sensors::ReadingPresenter.new(reading(battery_pct: nil)).battery_low?
    refute Sensors::ReadingPresenter.new(nil).battery_low?
  end

  test "age_label formats seconds, minutes, hours" do
    now = Time.utc(2026, 5, 12, 14, 0, 0)
    assert_equal "vor 30 s",   Sensors::ReadingPresenter.new(reading(taken_at: now - 30),    now: now).age_label
    assert_equal "vor 4 Min",  Sensors::ReadingPresenter.new(reading(taken_at: now - 4*60),  now: now).age_label
    assert_equal "vor 2 h",    Sensors::ReadingPresenter.new(reading(taken_at: now - 2*3600), now: now).age_label
  end

  test "age_label returns em-dash when reading is nil" do
    assert_equal "—", Sensors::ReadingPresenter.new(nil).age_label
  end

  test "offline? is true when reading is older than threshold" do
    now = Time.utc(2026, 5, 12, 14, 0, 0)
    fresh = reading(taken_at: now - 10.minutes)
    stale = reading(taken_at: now - 31.minutes)
    refute Sensors::ReadingPresenter.new(fresh, now: now).offline?
    assert Sensors::ReadingPresenter.new(stale, now: now).offline?
  end

  test "offline? is true when reading is nil" do
    assert Sensors::ReadingPresenter.new(nil).offline?
  end
end
