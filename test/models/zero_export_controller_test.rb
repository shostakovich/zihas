require "test_helper"

class ZeroExportControllerTest < ActiveSupport::TestCase
  setup { @tz = Time.zone; Time.zone = "Europe/Berlin" }
  teardown { Time.zone = @tz }

  def reading(soc:, pv:, temp: 30.0)
    SolakonReading.new(taken_at: Time.current, active_power_w: 0, pv_power_w: pv,
                       battery_power_w: 0, battery_soc_pct: soc, battery_temperature_c: temp)
  end

  def load(current:, night_base: 85.0, median: nil)
    attrs = { current_w: current, floor_w: 85.0, night_base_w: night_base }
    attrs[:median_w] = median unless median.nil?
    LoadEstimate.new(**attrs)
  end

  def sun(now)
    SunWindow.for(now: now, weather: nil, timezone: "Europe/Berlin")
  end

  def decide(reading:, load:, now:, previous_state: nil)
    ZeroExportController.decide(reading: reading, load: load, sun: sun(now),
                                previous_state: previous_state)
  end

  DAY     = -> { Time.zone.local(2026, 6, 20, 12, 0, 0) }
  EVENING = -> { Time.zone.local(2026, 6, 20, 21, 0, 0) }
  NIGHT   = -> { Time.zone.local(2026, 6, 20, 3, 0, 0) } # before 06:00 sunrise

  test "low soc protection passes PV only" do
    d = decide(reading: reading(soc: 10, pv: 100), load: load(current: 386), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 100, d.target_w
  end

  test "pv priority uses PV first then limited battery help" do
    d = decide(reading: reading(soc: 55, pv: 100), load: load(current: 386), now: DAY.call)
    assert_equal :pv_priority, d.state
    assert_equal 350, d.target_w # 100 PV + min(286, 250) help
  end

  test "hot battery enters protected and follows load capped at 800" do
    d = decide(reading: reading(soc: 55, pv: 700, temp: 45.0), load: load(current: 900), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 800, d.target_w
  end

  test "hot battery still tracks a low load below the 800 ceiling" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 180), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 180, d.target_w
  end

  test "thermal ceiling ramps linearly from 800W at 45C to 0W at 49C" do
    high = load(current: 900)
    assert_equal 800, decide(reading: reading(soc: 55, pv: 700, temp: 45.0), load: high, now: DAY.call).target_w
    assert_equal 600, decide(reading: reading(soc: 55, pv: 700, temp: 46.0), load: high, now: DAY.call).target_w
    assert_equal 400, decide(reading: reading(soc: 55, pv: 700, temp: 47.0), load: high, now: DAY.call).target_w
    assert_equal 200, decide(reading: reading(soc: 55, pv: 700, temp: 48.0), load: high, now: DAY.call).target_w
    assert_equal 0,   decide(reading: reading(soc: 55, pv: 700, temp: 49.0), load: high, now: DAY.call).target_w
  end

  test "above 49C discharge stays at zero" do
    d = decide(reading: reading(soc: 55, pv: 700, temp: 52.0), load: load(current: 900), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 0, d.target_w
  end

  test "throttled output still tracks a lower load" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 48.0), load: load(current: 150), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 150, d.target_w # below the 200W ceiling at 48C
  end

  test "thermal de-rating applies even at full charge" do
    d = decide(reading: reading(soc: 100, pv: 700, temp: 49.0), load: load(current: 900), now: DAY.call)
    assert_equal 0, d.target_w
  end

  test "thermal protection holds at 45.0 and releases at 44.9 (no hysteresis)" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 900),
               now: DAY.call, previous_state: :protected)
    assert_equal :protected, d.state
    assert_equal 800, d.target_w
  end

  test "thermal protection releases once cooled below 45" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 44.9), load: load(current: 300),
               now: DAY.call, previous_state: :protected)
    assert_equal :pv_priority, d.state
  end

  test "evening clamps to current load and never exports" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 200),
               now: EVENING.call)
    assert_equal :evening_catch_up, d.state
    assert_equal 200, d.target_w # falls fast to measured load, no export
  end

  test "target never exceeds the legal cap" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 2000),
               now: EVENING.call)
    assert_equal 800, d.target_w
  end

  test "median cap applies in pv priority" do
    d = decide(reading: reading(soc: 55, pv: 100), load: load(current: 800, median: 240), now: DAY.call)
    assert_equal :pv_priority, d.state
    assert_equal 240, d.target_w
  end

  test "median cap applies in evening catch up without slow rise" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 800, median: 240),
               now: EVENING.call)
    assert_equal :evening_catch_up, d.state
    assert_equal 240, d.target_w
  end

  test "median cap applies in protected output" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 800, median: 240),
               now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 240, d.target_w
  end

  test "load drop follows current load below median immediately" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 120, median: 240),
               now: EVENING.call)
    assert_equal :evening_catch_up, d.state
    assert_equal 120, d.target_w
  end

  test "falling target uses the smaller downward deadband" do
    d = ZeroExportController::Decision.new(state: :pv_priority, target_w: 180, deadband_w: 50)
    assert d.differs_from?(200)
  end

  test "rising target still uses the state's normal deadband" do
    d = ZeroExportController::Decision.new(state: :pv_priority, target_w: 230, deadband_w: 50)
    refute d.differs_from?(200)
  end

  test "night base uses base target minus reserve" do
    d = decide(reading: reading(soc: 20, pv: 0), load: load(current: 300, night_base: 85),
               now: NIGHT.call)
    assert_equal :night_base, d.state
    assert_equal 80, d.target_w
    assert_equal ZeroExportController::BASE_DEADBAND_W, d.deadband_w
  end
end
