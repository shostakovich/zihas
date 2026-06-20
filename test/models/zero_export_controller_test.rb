require "test_helper"

class ZeroExportControllerTest < ActiveSupport::TestCase
  setup { @tz = Time.zone; Time.zone = "Europe/Berlin" }
  teardown { Time.zone = @tz }

  def reading(soc:, pv:, temp: 30.0)
    SolakonReading.new(taken_at: Time.current, active_power_w: 0, pv_power_w: pv,
                       battery_power_w: 0, battery_soc_pct: soc, battery_temperature_c: temp)
  end

  def load(current:, night_base: 85.0)
    LoadEstimate.new(current_w: current, floor_w: 85.0, night_base_w: night_base)
  end

  def sun(now)
    SunWindow.for(now: now, weather: nil, timezone: "Europe/Berlin")
  end

  def decide(reading:, load:, now:, previous_state: nil, smoothed_load_w: nil)
    ZeroExportController.decide(reading: reading, load: load, sun: sun(now),
                                previous_state: previous_state, smoothed_load_w: smoothed_load_w)
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

  test "hot battery enters protected and follows load capped at 400" do
    d = decide(reading: reading(soc: 55, pv: 700, temp: 42.0), load: load(current: 900), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 400, d.target_w
  end

  test "hot battery still tracks a low load below the 400 ceiling" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 42.0), load: load(current: 180), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 180, d.target_w
  end

  test "thermal ceiling ramps linearly from 400W at 42C to 0W at 48C" do
    high = load(current: 900)
    assert_equal 400, decide(reading: reading(soc: 55, pv: 700, temp: 42.0), load: high, now: DAY.call).target_w
    assert_equal 300, decide(reading: reading(soc: 55, pv: 700, temp: 43.5), load: high, now: DAY.call).target_w
    assert_equal 200, decide(reading: reading(soc: 55, pv: 700, temp: 45.0), load: high, now: DAY.call).target_w
    assert_equal 100, decide(reading: reading(soc: 55, pv: 700, temp: 46.5), load: high, now: DAY.call).target_w
    assert_equal 0,   decide(reading: reading(soc: 55, pv: 700, temp: 48.0), load: high, now: DAY.call).target_w
  end

  test "above 48C discharge stays at zero" do
    d = decide(reading: reading(soc: 55, pv: 700, temp: 52.0), load: load(current: 900), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 0, d.target_w
  end

  test "throttled output still tracks a lower load" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 45.0), load: load(current: 150), now: DAY.call)
    assert_equal :protected, d.state
    assert_equal 150, d.target_w # below the 200W ceiling at 45C
  end

  test "thermal de-rating applies even at full charge" do
    d = decide(reading: reading(soc: 100, pv: 700, temp: 48.0), load: load(current: 900), now: DAY.call)
    assert_equal 0, d.target_w
  end

  test "thermal protection holds until cooled to 41.8" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 41.9), load: load(current: 900),
               now: DAY.call, previous_state: :protected)
    assert_equal :protected, d.state
    assert_equal 400, d.target_w
  end

  test "thermal protection releases once cooled" do
    d = decide(reading: reading(soc: 55, pv: 0, temp: 41.8), load: load(current: 300),
               now: DAY.call, previous_state: :protected)
    assert_equal :pv_priority, d.state
  end

  test "evening clamps to current load and never exports" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 200),
               now: EVENING.call, smoothed_load_w: 400.0)
    assert_equal :evening_catch_up, d.state
    assert_equal 200, d.target_w # falls fast to measured load, no export
  end

  test "target never exceeds the legal cap" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 2000),
               now: EVENING.call, smoothed_load_w: 2000.0)
    assert_equal 800, d.target_w
  end

  test "pv priority carries its real output forward for the next state's smoothing" do
    d = decide(reading: reading(soc: 90, pv: 250), load: load(current: 250), now: DAY.call)
    assert_equal :pv_priority, d.state
    assert_equal 250, d.target_w
    assert_in_delta 250.0, d.smoothed_load_w, 0.001
  end

  test "first evening tick ramps from the carried-forward output, not the current load" do
    # Simulates the sunset transition: the prior pv_priority tick output 250 W,
    # carried into smoothed_load_w. The evening target must ramp by <= 50 W, not
    # jump straight to the 800 W load (which would bypass the slow-up cap).
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 800),
               now: EVENING.call, smoothed_load_w: 250.0)
    assert_equal :evening_catch_up, d.state
    assert_equal 300, d.target_w # 250 + min(550*0.25, 50) = 300
  end

  test "cold-start evening seeds from base load rather than jumping to full load" do
    d = decide(reading: reading(soc: 90, pv: 0), load: load(current: 800, night_base: 85),
               now: EVENING.call, smoothed_load_w: nil)
    assert_equal :evening_catch_up, d.state
    assert_equal 135, d.target_w # rise_slow_fall_fast(800, 85) = 85 + min(178.75, 50) = 135
  end

  test "night base uses base target minus reserve" do
    d = decide(reading: reading(soc: 20, pv: 0), load: load(current: 300, night_base: 85),
               now: NIGHT.call)
    assert_equal :night_base, d.state
    assert_equal 80, d.target_w
    assert_equal ZeroExportController::BASE_DEADBAND_W, d.deadband_w
  end
end
