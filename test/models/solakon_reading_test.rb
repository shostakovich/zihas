require "test_helper"

class SolakonReadingTest < ActiveSupport::TestCase
  def reading(soc:, temp: nil, pv: 0)
    SolakonReading.new(taken_at: Time.current, active_power_w: 0,
                       pv_power_w: pv, battery_power_w: 0,
                       battery_soc_pct: soc, battery_temperature_c: temp)
  end

  test "soc protection thresholds" do
    assert reading(soc: 10).soc_below_minimum?
    assert_not reading(soc: 11).soc_below_minimum?
    assert reading(soc: 11).soc_at_resume?
    assert_not reading(soc: 10).soc_at_resume?
  end

  test "temperature hysteresis predicates" do
    assert reading(soc: 50, temp: 42.0).battery_hot?
    assert_not reading(soc: 50, temp: 41.9).battery_hot?
    assert reading(soc: 50, temp: 41.8).battery_cooled?
    assert_not reading(soc: 50, temp: 41.9).battery_cooled?
    assert reading(soc: 50, temp: nil).battery_cooled?
  end

  test "pv presence and usable energy" do
    assert reading(soc: 50, pv: 50).pv_present?
    assert_not reading(soc: 50, pv: 49).pv_present?
    assert_in_delta 0.0, reading(soc: 10).usable_wh, 0.001
    assert_in_delta 192.0, reading(soc: 20).usable_wh, 0.001
  end

  test "validates required fields" do
    reading = SolakonReading.new

    assert_not reading.valid?
    assert_includes reading.errors[:taken_at], "can't be blank"
    assert_includes reading.errors[:active_power_w], "can't be blank"
    assert_includes reading.errors[:pv_power_w], "can't be blank"
    assert_includes reading.errors[:battery_power_w], "can't be blank"
    assert_includes reading.errors[:battery_soc_pct], "can't be blank"
  end

test "validates power fields are numeric" do
  reading = SolakonReading.new(
    taken_at: Time.current,
    active_power_w: "not-a-number",
    pv_power_w: "also-not-a-number",
    battery_power_w: "still-not-a-number",
    battery_soc_pct: 80
  )

  assert_not reading.valid?
  assert_includes reading.errors[:active_power_w], "is not a number"
  assert_includes reading.errors[:pv_power_w], "is not a number"
  assert_includes reading.errors[:battery_power_w], "is not a number"
end

  test "latest_fresh returns newest reading inside stale threshold" do
    old = SolakonReading.create!(
      taken_at: 5.minutes.ago,
      active_power_w: 100,
      pv_power_w: 120,
      battery_power_w: 0,
      battery_soc_pct: 80
    )
    fresh = SolakonReading.create!(
      taken_at: 10.seconds.ago,
      active_power_w: 220,
      pv_power_w: 260,
      battery_power_w: -40,
      battery_soc_pct: 81
    )

    assert_equal fresh, SolakonReading.latest_fresh(stale_after_s: 120, now: Time.current)
    travel 3.minutes do
      assert_nil SolakonReading.latest_fresh(stale_after_s: 120, now: Time.current)
    end
  end

  test "battery_temperature_c is optional but must be numeric" do
    reading = SolakonReading.new(
      taken_at: Time.current, active_power_w: 1, pv_power_w: 2,
      battery_power_w: 3, battery_soc_pct: 55, battery_temperature_c: "hot"
    )
    assert_not reading.valid?
    assert_includes reading.errors[:battery_temperature_c], "is not a number"
  end

  # The real Solakon One reports register 39230 with charging as a POSITIVE raw
  # value (verified live: +14 W while charging, with PV > AC output). The display
  # value keeps the same sign convention shown to the user: charging +, discharging −.
  test "battery_display_power_w is positive while charging and negative while discharging" do
    charging = SolakonReading.new(battery_power_w: 50)
    discharging = SolakonReading.new(battery_power_w: -50)

    assert_equal 50, charging.battery_display_power_w
    assert_equal(-50, discharging.battery_display_power_w)
  end
end
