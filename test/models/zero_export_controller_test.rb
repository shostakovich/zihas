require "test_helper"

class ZeroExportControllerTest < ActiveSupport::TestCase
  setup { @tz = Time.zone; Time.zone = "Europe/Berlin" }
  teardown { Time.zone = @tz }

  def reading(soc:, pv:, temp: 30.0)
    SolakonReading.new(taken_at: Time.current, active_power_w: 0, pv_power_w: pv,
                       battery_power_w: 0, battery_soc_pct: soc, battery_temperature_c: temp)
  end

  def load(current:, median: nil)
    attrs = { current_w: current, floor_w: 85.0 }
    attrs[:median_w] = median unless median.nil?
    LoadEstimate.new(**attrs)
  end

  def decide(reading:, load:, previous_state: nil)
    ZeroExportController.decide(reading: reading, load: load, previous_state: previous_state)
  end

  test "low soc protection passes PV only" do
    d = decide(reading: reading(soc: 10, pv: 100), load: load(current: 386))
    assert_equal :protected, d.state
    assert_equal 100, d.target_w
  end

  test "normal mode covers the measured load from PV and battery" do
    d = decide(reading: reading(soc: 55, pv: 100), load: load(current: 386))
    assert_equal :normal, d.state
    assert_equal 386, d.target_w # full load, no battery-help cap
  end

  test "normal mode covers the load from the battery at night too" do
    d = decide(reading: reading(soc: 55, pv: 0), load: load(current: 300))
    assert_equal :normal, d.state
    assert_equal 300, d.target_w
  end

  test "hot battery enters protected and follows load capped at 800" do
    d = decide(reading: reading(soc: 55, pv: 700, temp: 45.0), load: load(current: 900))
    assert_equal :protected, d.state
    assert_equal 800, d.target_w
  end

  test "hot battery still tracks a low load below the 800 ceiling" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 180))
    assert_equal :protected, d.state
    assert_equal 180, d.target_w
  end

  test "thermal ceiling ramps linearly from 800W at 45C to 0W at 49C" do
    high = load(current: 900)
    assert_equal 800, decide(reading: reading(soc: 55, pv: 700, temp: 45.0), load: high).target_w
    assert_equal 600, decide(reading: reading(soc: 55, pv: 700, temp: 46.0), load: high).target_w
    assert_equal 400, decide(reading: reading(soc: 55, pv: 700, temp: 47.0), load: high).target_w
    assert_equal 200, decide(reading: reading(soc: 55, pv: 700, temp: 48.0), load: high).target_w
    assert_equal 0,   decide(reading: reading(soc: 55, pv: 700, temp: 49.0), load: high).target_w
  end

  test "above 49C discharge stays at zero" do
    d = decide(reading: reading(soc: 55, pv: 700, temp: 52.0), load: load(current: 900))
    assert_equal :protected, d.state
    assert_equal 0, d.target_w
  end

  test "throttled output still tracks a lower load" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 48.0), load: load(current: 150))
    assert_equal :protected, d.state
    assert_equal 150, d.target_w # below the 200W ceiling at 48C
  end

  test "thermal de-rating applies even at full charge" do
    d = decide(reading: reading(soc: 100, pv: 700, temp: 49.0), load: load(current: 900))
    assert_equal 0, d.target_w
  end

  test "thermal protection holds at 45.0 and releases at 44.9 (no hysteresis)" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 900),
               previous_state: :protected)
    assert_equal :protected, d.state
    assert_equal 800, d.target_w
  end

  test "thermal protection releases once cooled below 45" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 44.9), load: load(current: 300),
               previous_state: :protected)
    assert_equal :normal, d.state
  end

  test "target never exceeds the legal cap" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 2000))
    assert_equal :normal, d.state
    assert_equal 800, d.target_w
  end

  test "median cap applies in normal mode" do
    d = decide(reading: reading(soc: 55, pv: 100), load: load(current: 800, median: 240))
    assert_equal :normal, d.state
    assert_equal 240, d.target_w
  end

  test "median cap applies in protected output" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 800, median: 240))
    assert_equal :protected, d.state
    assert_equal 240, d.target_w
  end

  test "load drop follows current load below median immediately" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 120, median: 240))
    assert_equal :normal, d.state
    assert_equal 120, d.target_w
  end

  test "falling target uses the smaller downward deadband" do
    d = ZeroExportController::Decision.new(state: :normal, target_w: 180)
    assert d.differs_from?(200) # 20W drop clears the 15W downward deadband
  end

  test "rising target uses the normal deadband" do
    d = ZeroExportController::Decision.new(state: :normal, target_w: 230)
    refute d.differs_from?(200) # 30W rise stays inside the 50W normal deadband
  end
end
