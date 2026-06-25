# Solakon Control Algorithm Implementation Plan

> **Update (2026-06): partly superseded.** This plan built a four-state machine
> (`protected`, `pv_priority`, `evening_catch_up`, `night_base`). The controller
> was later reduced to two states — `PROTECTED` and the normal mode (`:normal`,
> formerly `:pv_priority`) — dropping the two nighttime modes, the 250 W
> battery-help cap, the `SunWindow` model, and `ConsumptionReader#night_base_w`.
> Tasks and tests referencing those removed pieces are historical. See the design
> doc's update note for details.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current Solakon zero-export recovery behavior with a PV-priority, low-SoC- and temperature-protected, sparse-write control algorithm built from small value objects.

**Architecture:** Keep Modbus access in `SolakonClient`, persistence in `SolakonReading`, load estimation in `ConsumptionReader`. Control decisions are a pure policy in `ZeroExportController` that consumes value objects (`SolakonReading` with battery-safety predicates, `SunWindow`, `LoadEstimate`) instead of a long scalar parameter list. `ZeroExportTickJob` builds those value objects from live state and config, applies a sparse-write policy with a watchdog heartbeat, and handles fail-safe release.

**Tech Stack:** Ruby on Rails 8.1, Minitest, ActiveRecord, Rails.cache, Modbus TCP through `rmodbus`, `SunCalc` (local NOAA solar position).

## Global Constraints

- **Tuning lives in code, not config.** Only deployment/topology values stay in `config/ziwoas.yml` under `solakon` (`host`, `port`, `unit_id`, `monitoring_enabled`, `control_enabled`, `stale_after_s`). Every algorithm threshold below is a Ruby constant on the object that owns the concern. Do **not** add algorithm knobs to `SolakonCfg`.
- **Legal output cap:** the AC active-power target must never exceed `800 W` (balcony-PV limit), in every state.
- **Battery floor:** the inverter minimum-SoC register stays at `10 %`; the controller is best-effort above that and never relies on commanding the inverter below it.
- **Watchdog:** `SolakonClient::REMOTE_TIMEOUT_S` is `150 s`. Remote control must be re-armed before it expires; the heartbeat is `120 s`.
- **Export safety:** the original zero-export invariant (`output ≤ measured load`) must hold in `PV_PRIORITY` and `EVENING_CATCH_UP` by clamping the target to the current measured load. `NIGHT_BASE` intentionally uses a flat historical setpoint and accepts small grid deviations (decision accepted by the owner).
- **Constant ownership:**
  - `SolakonReading` (battery safety domain): `MIN_SOC_PCT = 10`, `RESUME_SOC_PCT = 11`, `HOT_TEMP_C = 42.0`, `HOT_RESUME_TEMP_C = 41.8`, `PV_PRESENT_W = 50`, `USABLE_CAPACITY_WH = 1920`.
  - `ZeroExportController` (control policy): `MAX_OUTPUT_W = 800`, `DAY_BATTERY_HELP_W = 250`, `EVENING_DISCHARGE_LIMIT_W = 800`, `HOT_OUTPUT_LIMIT_W = 400`, `NORMAL_DEADBAND_W = 50`, `BASE_DEADBAND_W = 15`, `NIGHT_BASE_RESERVE_W = 5`, `RISE_FACTOR = 0.25`, `RISE_CAP_W = 50`, `FALL_FACTOR = 0.8`.
  - `ConsumptionReader`: `NIGHT_BASE_DAYS = 7`.
  - `SunWindow`: `FALLBACK_SUNRISE_HOUR = 6`, `FALLBACK_SUNSET_HOUR = 20`.
  - `ZeroExportTickJob`: `HEARTBEAT_S = 120`, night-base cache TTL `1.hour`.

---

## File Structure

- `lib/solakon_client.rb` — add BMS max-temperature read to `State`.
- `db/migrate/20260620120000_add_battery_temperature_to_solakon_readings.rb` — nullable temperature column.
- `app/models/solakon_reading.rb` — persist temperature; **own battery-safety constants and predicates** (`soc_below_minimum?`, `soc_at_resume?`, `battery_hot?`, `battery_cooled?`, `pv_present?`, `usable_wh`).
- `app/jobs/solakon_monitor_job.rb` — persist `battery_temperature_c`.
- `app/models/sun_window.rb` — value object: `daytime?`, `hours_until_sunrise` with correct *next* sunrise and 06:00/20:00 fallback.
- `app/models/load_estimate.rb` — value object bundling `current_w`/`floor_w`/`night_base_w` with `effective_w`.
- `app/models/consumption_reader.rb` — add `night_base_w` (P20 of recent night buckets, fallback to floor).
- `app/models/zero_export_controller.rb` — replace scalar `target_output_w` with pure `decide(...)` returning a `Decision`, state machine, target functions, asymmetric smoothing.
- `app/jobs/zero_export_tick_job.rb` — build value objects, cache night base, sparse-write policy with heartbeat (`LastWrite` value object + prose predicates), fail-safe release, remove recovery cache.
- `docs/superpowers/specs/2026-06-20-solakon-control-algorithm-design.md` — align thermal-protection and constants-in-code wording.

---

## Task 1: Read And Persist Battery Temperature

**Files:**
- Modify: `lib/solakon_client.rb`
- Create: `db/migrate/20260620120000_add_battery_temperature_to_solakon_readings.rb`
- Modify: `app/models/solakon_reading.rb`
- Modify: `app/jobs/solakon_monitor_job.rb`
- Test: `test/solakon_client_test.rb`, `test/models/solakon_reading_test.rb`, `test/jobs/solakon_monitor_job_test.rb`

**Interfaces:**
- Produces: `SolakonClient::State#battery_temperature_c` (Float °C, nil-safe), `SolakonReading#battery_temperature_c` (Float, nullable).

- [ ] **Step 1: Write the failing client test**

In `test/solakon_client_test.rb`, add `[ 37617, 1 ] => [ 423 ]` to the holding-register stub used by `test_read_state_decodes_signed_values_via_fc03`, and assert:

```ruby
assert_in_delta 42.3, state.battery_temperature_c, 0.001
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bin/rails test test/solakon_client_test.rb`
Expected: FAIL — `battery_temperature_c` is not a member of `State`.

- [ ] **Step 3: Implement the temperature read**

In `lib/solakon_client.rb` add the register and struct member:

```ruby
REG_BMS_MAX_TEMP = 37617 # i16, scale 10, Celsius

State = Struct.new(:battery_soc, :active_power_w, :pv_power_w, :battery_power_w,
                   :battery_temperature_c, keyword_init: true)
```

In `read_state_from`, add the field:

```ruby
battery_temperature_c: to_i16(slave.read_holding_registers(REG_BMS_MAX_TEMP, 1).first) / 10.0,
```

- [ ] **Step 4: Run the client test to confirm it passes**

Run: `bin/rails test test/solakon_client_test.rb`
Expected: PASS.

- [ ] **Step 5: Write failing persistence tests**

In `test/models/solakon_reading_test.rb`:

```ruby
test "battery_temperature_c is optional but must be numeric" do
  reading = SolakonReading.new(
    taken_at: Time.current, active_power_w: 1, pv_power_w: 2,
    battery_power_w: 3, battery_soc_pct: 55, battery_temperature_c: "hot"
  )
  assert_not reading.valid?
  assert_includes reading.errors[:battery_temperature_c], "is not a number"
end
```

In `test/jobs/solakon_monitor_job_test.rb`, add `battery_temperature_c: 42.3` to every `SolakonClient::State.new(...)` and assert:

```ruby
assert_in_delta 42.3, reading.battery_temperature_c, 0.001
```

- [ ] **Step 6: Run them to confirm they fail**

Run: `bin/rails test test/models/solakon_reading_test.rb test/jobs/solakon_monitor_job_test.rb`
Expected: FAIL — column and assignment missing.

- [ ] **Step 7: Add migration, validation, and monitor assignment**

Create `db/migrate/20260620120000_add_battery_temperature_to_solakon_readings.rb`:

```ruby
class AddBatteryTemperatureToSolakonReadings < ActiveRecord::Migration[8.1]
  def change
    add_column :solakon_readings, :battery_temperature_c, :float
  end
end
```

In `app/models/solakon_reading.rb`:

```ruby
validates :battery_temperature_c, numericality: true, allow_nil: true
```

In `app/jobs/solakon_monitor_job.rb`, add to the `create!` call:

```ruby
battery_temperature_c: state.battery_temperature_c
```

- [ ] **Step 8: Migrate and run the tests**

Run: `bin/rails db:migrate RAILS_ENV=test`
Run: `bin/rails test test/solakon_client_test.rb test/models/solakon_reading_test.rb test/jobs/solakon_monitor_job_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/solakon_client.rb app/models/solakon_reading.rb app/jobs/solakon_monitor_job.rb db/migrate/20260620120000_add_battery_temperature_to_solakon_readings.rb db/schema.rb test/solakon_client_test.rb test/models/solakon_reading_test.rb test/jobs/solakon_monitor_job_test.rb
git commit -m "feat: store Solakon battery temperature"
```

---

## Task 2: Battery-Safety Predicates On SolakonReading

Move battery-safety knowledge onto the battery domain object so the controller reads like prose (`reading.battery_hot?`) instead of comparing scalars.

**Files:**
- Modify: `app/models/solakon_reading.rb`
- Test: `test/models/solakon_reading_test.rb`

**Interfaces:**
- Produces: constants `SolakonReading::MIN_SOC_PCT (10)`, `RESUME_SOC_PCT (11)`, `HOT_TEMP_C (42.0)`, `HOT_RESUME_TEMP_C (41.8)`, `PV_PRESENT_W (50)`, `USABLE_CAPACITY_WH (1920)`; predicates `soc_below_minimum?`, `soc_at_resume?`, `battery_hot?`, `battery_cooled?`, `pv_present?`; `usable_wh` (Float). All read in-memory attributes, so an **unsaved** `SolakonReading` built from a live `SolakonClient::State` works the same as a persisted row.

- [ ] **Step 1: Write the failing predicate tests**

In `test/models/solakon_reading_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bin/rails test test/models/solakon_reading_test.rb`
Expected: FAIL — predicates undefined.

- [ ] **Step 3: Implement constants and predicates**

In `app/models/solakon_reading.rb` (inside the class body):

```ruby
MIN_SOC_PCT       = 10
RESUME_SOC_PCT    = 11
HOT_TEMP_C        = 42.0
HOT_RESUME_TEMP_C = 41.8
PV_PRESENT_W      = 50
USABLE_CAPACITY_WH = 1920

def soc_below_minimum? = battery_soc_pct <= MIN_SOC_PCT
def soc_at_resume?     = battery_soc_pct >= RESUME_SOC_PCT
def battery_hot?       = battery_temperature_c.present? && battery_temperature_c >= HOT_TEMP_C
def battery_cooled?    = battery_temperature_c.blank? || battery_temperature_c <= HOT_RESUME_TEMP_C
def pv_present?        = pv_power_w.to_f >= PV_PRESENT_W

def usable_wh
  [ battery_soc_pct - MIN_SOC_PCT, 0 ].max / 100.0 * USABLE_CAPACITY_WH
end
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `bin/rails test test/models/solakon_reading_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/solakon_reading.rb test/models/solakon_reading_test.rb
git commit -m "feat: add Solakon battery safety predicates"
```

---

## Task 3: SunWindow Value Object

Encapsulate day/night logic and guarantee `hours_until_sunrise` always uses the **next upcoming** sunrise (the bug that otherwise collapses the night energy budget). Fall back to 06:00/20:00 when no weather location is configured.

**Files:**
- Create: `app/models/sun_window.rb`
- Test: `test/models/sun_window_test.rb`

**Interfaces:**
- Consumes: `SunCalc.sunrise/sunset(date:, lat:, lon:, timezone:)` (returns a UTC `Time` or `nil`).
- Produces: `SunWindow.for(now:, weather:, timezone:)` where `weather` responds to `lat`/`lon` or is `nil`; instance methods `daytime?` (Boolean) and `hours_until_sunrise` (Float ≥ 0).

- [ ] **Step 1: Write the failing tests**

`test/models/sun_window_test.rb`:

```ruby
require "test_helper"

class SunWindowTest < ActiveSupport::TestCase
  setup { @tz = Time.zone; Time.zone = "Europe/Berlin" }
  teardown { Time.zone = @tz }

  test "without weather it falls back to 06:00 and 20:00" do
    midday = Time.zone.local(2026, 6, 20, 12, 0, 0)
    win = SunWindow.for(now: midday, weather: nil, timezone: "Europe/Berlin")
    assert win.daytime?

    night = Time.zone.local(2026, 6, 20, 22, 0, 0)
    win2 = SunWindow.for(now: night, weather: nil, timezone: "Europe/Berlin")
    assert_not win2.daytime?
  end

  test "hours_until_sunrise uses tomorrow's sunrise late at night" do
    night = Time.zone.local(2026, 6, 20, 22, 0, 0) # after 06:00 fallback sunrise
    win = SunWindow.for(now: night, weather: nil, timezone: "Europe/Berlin")
    # next sunrise is 06:00 on the 21st => 8 hours away, never 0
    assert_in_delta 8.0, win.hours_until_sunrise, 0.001
  end

  test "hours_until_sunrise uses today's sunrise in the early morning" do
    early = Time.zone.local(2026, 6, 20, 3, 0, 0) # before 06:00 fallback sunrise
    win = SunWindow.for(now: early, weather: nil, timezone: "Europe/Berlin")
    assert_in_delta 3.0, win.hours_until_sunrise, 0.001
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bin/rails test test/models/sun_window_test.rb`
Expected: FAIL — `SunWindow` undefined.

- [ ] **Step 3: Implement SunWindow**

`app/models/sun_window.rb`:

```ruby
# Day/night window for one instant. Guarantees hours_until_sunrise is measured
# against the *next* sunrise (today's if we are before it, tomorrow's if past),
# so the night energy budget never collapses to zero late at night.
class SunWindow
  FALLBACK_SUNRISE_HOUR = 6
  FALLBACK_SUNSET_HOUR  = 20

  def self.for(now:, weather:, timezone:)
    date = now.to_date
    if weather
      sunrise = SunCalc.sunrise(date: date, lat: weather.lat, lon: weather.lon, timezone: timezone)
      sunset  = SunCalc.sunset(date: date, lat: weather.lat, lon: weather.lon, timezone: timezone)
      next_sr = SunCalc.sunrise(date: date + 1, lat: weather.lat, lon: weather.lon, timezone: timezone)
    end
    sunrise ||= now.change(hour: FALLBACK_SUNRISE_HOUR, min: 0)
    sunset  ||= now.change(hour: FALLBACK_SUNSET_HOUR, min: 0)
    next_sr ||= sunrise + 1.day

    new(now: now, sunrise: sunrise, sunset: sunset,
        next_sunrise: now < sunrise ? sunrise : next_sr)
  end

  def initialize(now:, sunrise:, sunset:, next_sunrise:)
    @now = now
    @sunrise = sunrise
    @sunset = sunset
    @next_sunrise = next_sunrise
  end

  def daytime?
    @now >= @sunrise && @now < @sunset
  end

  def hours_until_sunrise
    [ (@next_sunrise - @now) / 3600.0, 0.0 ].max
  end
end
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `bin/rails test test/models/sun_window_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/sun_window.rb test/models/sun_window_test.rb
git commit -m "feat: add SunWindow day/night value object"
```

---

## Task 4: LoadEstimate Value Object And Night Base Load

Bundle the three load inputs into one value object, and add the P20 night-base estimator (the controller's `NIGHT_BASE` setpoint source).

**Files:**
- Create: `app/models/load_estimate.rb`
- Modify: `app/models/consumption_reader.rb`
- Test: `test/models/load_estimate_test.rb`, `test/models/consumption_reader_test.rb`

**Interfaces:**
- Produces: `LoadEstimate.new(current_w:, floor_w:, night_base_w:)` with `effective_w` (Float; `current_w` when present else `floor_w`).
- Produces: `ConsumptionReader::NIGHT_BASE_DAYS (7)`; `ConsumptionReader#night_base_w(lat:, lon:, timezone:, days: NIGHT_BASE_DAYS, fallback_w: nil)` → Float. Heavy query; the job caches the result (Task 6).

- [ ] **Step 1: Write the failing LoadEstimate test**

`test/models/load_estimate_test.rb`:

```ruby
require "test_helper"

class LoadEstimateTest < ActiveSupport::TestCase
  test "effective_w prefers live consumption" do
    est = LoadEstimate.new(current_w: 240.0, floor_w: 85.0, night_base_w: 90.0)
    assert_in_delta 240.0, est.effective_w, 0.001
  end

  test "effective_w falls back to floor when live load is nil" do
    est = LoadEstimate.new(current_w: nil, floor_w: 85.0, night_base_w: 90.0)
    assert_in_delta 85.0, est.effective_w, 0.001
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bin/rails test test/models/load_estimate_test.rb`
Expected: FAIL — `LoadEstimate` undefined.

- [ ] **Step 3: Implement LoadEstimate**

`app/models/load_estimate.rb`:

```ruby
# The household-load inputs the controller needs, in one place. current_w is the
# live measured sum (nil when no fresh sample); floor_w is the export-safe 24h
# minimum; night_base_w is the expected overnight base load.
LoadEstimate = Struct.new(:current_w, :floor_w, :night_base_w, keyword_init: true) do
  def effective_w
    (current_w || floor_w).to_f
  end
end
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `bin/rails test test/models/load_estimate_test.rb`
Expected: PASS.

- [ ] **Step 5: Write the failing night-base tests**

In `test/models/consumption_reader_test.rb` (wrap with `Time.zone = "Europe/Berlin"` in setup/teardown). Build two consumer plugs and seed 5-minute buckets across a recent stable night between sunset and sunrise:

```ruby
test "night_base_w returns P20 of recent night buckets" do
  # seed buckets so the per-bucket consumer total is mostly ~85W with a few spikes
  reader = ConsumptionReader.new(plugs: plugs, now: Time.zone.local(2026, 6, 20, 10, 0, 0))
  assert_in_delta 85.0,
    reader.night_base_w(lat: 52.52, lon: 13.405, timezone: "Europe/Berlin", days: 7, fallback_w: 120),
    0.001
end

test "night_base_w falls back when there is no night data" do
  reader = ConsumptionReader.new(plugs: plugs, now: Time.zone.local(2026, 6, 20, 10, 0, 0))
  assert_in_delta 120.0,
    reader.night_base_w(lat: 52.52, lon: 13.405, timezone: "Europe/Berlin", days: 7, fallback_w: 120),
    0.001
end
```

- [ ] **Step 6: Run them to confirm they fail**

Run: `bin/rails test test/models/consumption_reader_test.rb`
Expected: FAIL — `night_base_w` undefined.

- [ ] **Step 7: Implement the P20 estimator**

In `app/models/consumption_reader.rb`:

```ruby
NIGHT_BASE_DAYS      = 7
NIGHT_EDGE_EXCLUSION_S = 60 * 60

def night_base_w(lat:, lon:, timezone:, days: NIGHT_BASE_DAYS, fallback_w: nil)
  totals = night_bucket_totals(lat: lat, lon: lon, timezone: timezone, days: days.to_i)
  return fallback_w.to_f if totals.empty? && !fallback_w.nil?
  return guaranteed_floor_w if totals.empty?

  sorted = totals.sort
  sorted[((sorted.length - 1) * 0.20).floor].to_f
end

private

def night_bucket_totals(lat:, lon:, timezone:, days:)
  return [] if @consumer_ids.empty?
  ranges = night_ranges(lat: lat, lon: lon, timezone: timezone, days: days)
  return [] if ranges.empty?

  cutoff = ranges.map(&:first).min.to_i
  rows = Sample
    .where(plug_id: @consumer_ids)
    .where("ts >= ?", cutoff)
    .group("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S}"))
    .select("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S} AS bucket_ts"), Arel.sql("AVG(apower_w) AS avg_w"))

  totals = Hash.new(0.0)
  rows.each do |row|
    bucket_ts = row.bucket_ts.to_i
    next unless ranges.any? { |start_at, end_at| bucket_ts >= start_at.to_i && bucket_ts < end_at.to_i }
    totals[bucket_ts] += row.avg_w.to_f
  end
  totals.values
end

def night_ranges(lat:, lon:, timezone:, days:)
  tz = TZInfo::Timezone.get(timezone)
  today = tz.utc_to_local(@now.to_time.utc).to_date
  (1..days).filter_map do |offset|
    sunset_date  = today - offset
    sunrise_date = sunset_date + 1
    sunset  = SunCalc.sunset(date: sunset_date, lat: lat, lon: lon, timezone: timezone)
    sunrise = SunCalc.sunrise(date: sunrise_date, lat: lat, lon: lon, timezone: timezone)
    next if sunset.nil? || sunrise.nil?
    [ sunset + NIGHT_EDGE_EXCLUSION_S, sunrise - NIGHT_EDGE_EXCLUSION_S ]
  end
end
```

- [ ] **Step 8: Run them to confirm they pass**

Run: `bin/rails test test/models/consumption_reader_test.rb test/models/load_estimate_test.rb`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add app/models/load_estimate.rb app/models/consumption_reader.rb test/models/load_estimate_test.rb test/models/consumption_reader_test.rb
git commit -m "feat: estimate Solakon night base load"
```

---

## Task 5: Pure Control Policy In ZeroExportController

Replace the scalar `target_output_w` with a pure `decide(...)` that takes value objects and returns a `Decision`. State machine: `protected`, `pv_priority`, `evening_catch_up`, `night_base`.

**Files:**
- Modify: `app/models/zero_export_controller.rb`
- Test: `test/models/zero_export_controller_test.rb`

**Interfaces:**
- Consumes: `SolakonReading` (predicates from Task 2, plus `pv_power_w`), `LoadEstimate` (Task 4), `SunWindow` (Task 3).
- Produces: `ZeroExportController.decide(reading:, load:, sun:, previous_state:, smoothed_load_w:)` → `Decision`. `Decision = Struct(:state (Symbol), :target_w (Integer), :deadband_w (Integer), :smoothed_load_w (Float|nil))` with `#differs_from?(previous_target_w)`. Control constants listed in Global Constraints.

**Behavior notes (locked by the owner):**
- **Thermal protection follows load down, capped at 400 W.** Less inverter throughput means less internal heat, so the target tracks actual consumption and `HOT_OUTPUT_LIMIT_W` is only the ceiling. The Solakon One splits battery↔PV internally; we never write the discharge-current-limit register.
- Thermal protection is a real state with hysteresis: enter at `battery_hot?` (≥42.0 °C), stay until `battery_cooled?` (≤41.8 °C).
- Low-SoC protection: no intentional discharge (PV only) until `soc_at_resume?` (≥11 %).

- [ ] **Step 1: Write the failing policy tests**

Replace the body of `test/models/zero_export_controller_test.rb`:

```ruby
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

  test "night base uses base target minus reserve" do
    d = decide(reading: reading(soc: 20, pv: 0), load: load(current: 300, night_base: 85),
               now: NIGHT.call)
    assert_equal :night_base, d.state
    assert_equal 80, d.target_w
    assert_equal ZeroExportController::BASE_DEADBAND_W, d.deadband_w
  end
end
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `bin/rails test test/models/zero_export_controller_test.rb`
Expected: FAIL — `decide`/`Decision` undefined.

- [ ] **Step 3: Implement the pure policy**

Replace `app/models/zero_export_controller.rb`:

```ruby
# Pure control policy for the Solakon One. Chooses a coarse state, then a watt
# target with simple pure functions. Battery-safety thresholds live on
# SolakonReading; control tuning lives here as constants.
class ZeroExportController
  MAX_OUTPUT_W             = 800   # legal balcony-PV feed limit
  DAY_BATTERY_HELP_W       = 250   # max daytime battery assist
  EVENING_DISCHARGE_LIMIT_W = 800
  HOT_OUTPUT_LIMIT_W       = 400   # thermal throttle ceiling (still follows load)
  NORMAL_DEADBAND_W        = 50
  BASE_DEADBAND_W          = 15
  NIGHT_BASE_RESERVE_W     = 5
  RISE_FACTOR              = 0.25  # slow up: take 25% of the gap...
  RISE_CAP_W               = 50    # ...but at most 50W per tick
  FALL_FACTOR              = 0.80  # fast down

  Decision = Struct.new(:state, :target_w, :deadband_w, :smoothed_load_w, keyword_init: true) do
    def differs_from?(previous_target_w)
      (target_w - previous_target_w.to_i).abs >= deadband_w
    end
  end

  def self.decide(reading:, load:, sun:, previous_state:, smoothed_load_w:)
    state = choose_state(reading: reading, sun: sun, load: load, previous_state: previous_state)
    raw, smoothed = target_for(state, reading: reading, load: load, smoothed_load_w: smoothed_load_w)

    Decision.new(
      state: state,
      target_w: raw.to_f.clamp(0.0, MAX_OUTPUT_W).round,
      deadband_w: state == :night_base ? BASE_DEADBAND_W : NORMAL_DEADBAND_W,
      smoothed_load_w: smoothed
    )
  end

  def self.choose_state(reading:, sun:, load:, previous_state:)
    return :protected if protecting?(reading, previous_state)
    return :pv_priority if sun.daytime? || reading.pv_present?

    enough_for_morning?(reading, sun, load) ? :night_base : :evening_catch_up
  end

  # Enter protection on a hard limit; once in it, stay until BOTH the SoC has
  # resumed and the battery has cooled (hysteresis around the entry thresholds).
  def self.protecting?(reading, previous_state)
    return true if reading.soc_below_minimum? || reading.battery_hot?
    return false unless previous_state == :protected

    !(reading.soc_at_resume? && reading.battery_cooled?)
  end

  def self.enough_for_morning?(reading, sun, load)
    reading.usable_wh <= load.night_base_w * sun.hours_until_sunrise
  end

  def self.target_for(state, reading:, load:, smoothed_load_w:)
    case state
    when :protected
      [ protected_target(reading, load), nil ]
    when :pv_priority
      [ pv_priority_target(reading, load), nil ]
    when :evening_catch_up
      smoothed = rise_slow_fall_fast(load.effective_w, smoothed_load_w || load.effective_w)
      [ [ smoothed, load.effective_w, EVENING_DISCHARGE_LIMIT_W ].min, smoothed ]
    when :night_base
      [ [ load.night_base_w - NIGHT_BASE_RESERVE_W, load.effective_w ].min, nil ]
    end
  end

  # Below resume SoC: no intentional discharge (PV only). Above it: normal PV
  # priority. While the battery is still warm, throttle the *whole* AC output to
  # the hot ceiling — but always follow the (lower) load, since less throughput
  # means less inverter heat.
  def self.protected_target(reading, load)
    base = reading.soc_at_resume? ? pv_priority_target(reading, load) : [ reading.pv_power_w, load.effective_w ].min
    ceiling = reading.battery_cooled? ? MAX_OUTPUT_W : HOT_OUTPUT_LIMIT_W
    [ base, ceiling ].min
  end

  def self.pv_priority_target(reading, load)
    pv_direct = [ reading.pv_power_w, load.effective_w ].min
    remaining = [ load.effective_w - pv_direct, 0.0 ].max
    pv_direct + [ remaining, DAY_BATTERY_HELP_W ].min
  end

  def self.rise_slow_fall_fast(load_w, previous_w)
    step = load_w - previous_w
    return previous_w + [ step * RISE_FACTOR, RISE_CAP_W ].min if step.positive?

    previous_w + step * FALL_FACTOR
  end
end
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `bin/rails test test/models/zero_export_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/zero_export_controller.rb test/models/zero_export_controller_test.rb
git commit -m "feat: add Solakon PV-priority control policy"
```

---

## Task 6: Integrate Policy In ZeroExportTickJob With Sparse Writes

Wire the value objects into the tick job, cache the night base, apply a sparse-write policy with a watchdog heartbeat, and keep fail-safe release. Remove the old recovery cache.

**Files:**
- Modify: `app/jobs/zero_export_tick_job.rb`
- Test: `test/jobs/zero_export_tick_job_test.rb`

**Interfaces:**
- Consumes: everything above; `config.weather` (nil-able `WeatherCfg` with `lat`/`lon`), `config.timezone` (String).
- Produces: side effects only (Modbus writes, logs). Internal `LastWrite = Struct(:state, :target_w, :at)` value object loaded from cache.

- [ ] **Step 1: Write the failing job tests**

In `test/jobs/zero_export_tick_job_test.rb`, keep the existing `FakeClient` that records `:read_state`, `[:apply_power, w, soc]`, and `:release`. Add:

```ruby
test "low soc passes PV only and no longer runs recovery" do
  now = Time.zone.local(2026, 6, 20, 12, 0, 0)
  Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 386, aenergy_wh: 1)
  client = FakeClient.new(state: state_with(soc: 10, pv: 100, temp: 30))

  run_job(client: client, now: now)

  assert_equal [ :read_state, [ :apply_power, 100, 10 ] ], client.calls
end

test "does not rewrite inside the deadband before the heartbeat" do
  now = Time.zone.local(2026, 6, 20, 12, 0, 0)
  Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 386, aenergy_wh: 1)

  run_job(client: FakeClient.new(state: state_with(soc: 55, pv: 100, temp: 30)), now: now)
  second = FakeClient.new(state: state_with(soc: 55, pv: 100, temp: 30))
  run_job(client: second, now: now + 30.seconds)

  assert_equal [ :read_state ], second.calls
end

test "heartbeat rewrites the unchanged target before the watchdog expires" do
  now = Time.zone.local(2026, 6, 20, 12, 0, 0)
  Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 386, aenergy_wh: 1)

  run_job(client: FakeClient.new(state: state_with(soc: 55, pv: 100, temp: 30)), now: now)
  heartbeat = FakeClient.new(state: state_with(soc: 55, pv: 100, temp: 30))
  run_job(client: heartbeat, now: now + 121.seconds)

  assert_includes heartbeat.calls, [ :apply_power, 350, 10 ]
end

test "hot battery clamps the whole target to 400W" do
  now = Time.zone.local(2026, 6, 20, 12, 0, 0)
  Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 900, aenergy_wh: 1)
  client = FakeClient.new(state: state_with(soc: 55, pv: 700, temp: 42))

  run_job(client: client, now: now)

  assert_includes client.calls, [ :apply_power, 400, 10 ]
end
```

Add a `state_with(soc:, pv:, temp:)` helper that builds a `SolakonClient::State` including `battery_temperature_c: temp`, and ensure `run_job` clears `Rails.cache` between the independent test scenarios.

- [ ] **Step 2: Run them to confirm they fail**

Run: `bin/rails test test/jobs/zero_export_tick_job_test.rb`
Expected: FAIL — recovery/always-write behavior still present.

- [ ] **Step 3: Replace the job body**

Rewrite `app/jobs/zero_export_tick_job.rb`:

```ruby
require "config_loader"
require "solakon_client"

class ZeroExportTickJob < ApplicationJob
  queue_as :default

  FLOOR_CACHE_KEY         = "zero_export.floor_w".freeze
  NIGHT_BASE_CACHE_KEY    = "zero_export.night_base_w".freeze
  STATE_CACHE_KEY         = "zero_export.state".freeze
  LAST_TARGET_CACHE_KEY   = "zero_export.last_target_w".freeze
  LAST_WRITE_AT_CACHE_KEY = "zero_export.last_write_at".freeze
  SMOOTHED_LOAD_CACHE_KEY = "zero_export.smoothed_load_w".freeze
  FAILURE_COUNT_CACHE_KEY = "zero_export.consecutive_failures".freeze

  SLOW_QUERY_TTL           = 1.hour
  HEARTBEAT_S              = 120
  MAX_CONSECUTIVE_FAILURES = 3

  LastWrite = Struct.new(:state, :target_w, :at, keyword_init: true) do
    def self.from_cache
      at = Rails.cache.read(LAST_WRITE_AT_CACHE_KEY)
      new(state: Rails.cache.read(STATE_CACHE_KEY)&.to_sym,
          target_w: Rails.cache.read(LAST_TARGET_CACHE_KEY), at: at)
    end

    def missing? = at.nil? || target_w.nil?
  end

  def perform(client: nil, reader_now: Time.current, state: nil)
    config  = ConfigLoader.app_config
    solakon = config.solakon
    return Rails.logger.info("zero_export: not configured") if solakon.nil?
    return Rails.logger.info("zero_export: control disabled") unless solakon.control_enabled

    reader = ConsumptionReader.new(plugs: config.plugs, now: reader_now, stale_after_s: solakon.stale_after_s)
    floor  = Rails.cache.fetch(FLOOR_CACHE_KEY, expires_in: SLOW_QUERY_TTL) { reader.guaranteed_floor_w }
    night_base = night_base_w(reader, config, floor)
    load = LoadEstimate.new(current_w: reader.current_consumption_w, floor_w: floor, night_base_w: night_base)

    client ||= SolakonClient.new(host: solakon.host, port: solakon.port, unit_id: solakon.unit_id)

    begin
      state ||= client.read_state
      reading = reading_from(state, reader_now)
      sun = SunWindow.for(now: reader_now, weather: config.weather, timezone: config.timezone)

      decision = ZeroExportController.decide(
        reading: reading, load: load, sun: sun,
        previous_state: Rails.cache.read(STATE_CACHE_KEY)&.to_sym,
        smoothed_load_w: Rails.cache.read(SMOOTHED_LOAD_CACHE_KEY)
      )

      write_target!(client, decision, reader_now) if should_write?(decision, reader_now)
      remember(decision)
      reset_failures
      log(decision, load, reading)
    rescue SolakonClient::Error => e
      handle_failure(client, e)
    end
  end

  private

  def night_base_w(reader, config, floor)
    return floor if config.weather.nil?

    Rails.cache.fetch(NIGHT_BASE_CACHE_KEY, expires_in: SLOW_QUERY_TTL) do
      reader.night_base_w(lat: config.weather.lat, lon: config.weather.lon,
                          timezone: config.timezone,
                          days: ConsumptionReader::NIGHT_BASE_DAYS, fallback_w: floor)
    end
  end

  def reading_from(state, now)
    SolakonReading.new(taken_at: now, active_power_w: state.active_power_w,
                       pv_power_w: state.pv_power_w, battery_power_w: state.battery_power_w,
                       battery_soc_pct: state.battery_soc, battery_temperature_c: state.battery_temperature_c)
  end

  # Reads like the policy: write on a new state, when the watchdog heartbeat is
  # due, or when the target has moved beyond its deadband.
  def should_write?(decision, now)
    last = LastWrite.from_cache
    return true if last.missing?

    last.state != decision.state ||
      heartbeat_due?(last, now) ||
      decision.differs_from?(last.target_w)
  end

  def heartbeat_due?(last, now)
    (now - last.at) >= HEARTBEAT_S
  end

  def write_target!(client, decision, now)
    client.apply_control!(power_w: decision.target_w, min_soc: SolakonReading::MIN_SOC_PCT)
    Rails.cache.write(LAST_TARGET_CACHE_KEY, decision.target_w)
    Rails.cache.write(LAST_WRITE_AT_CACHE_KEY, now)
  end

  def remember(decision)
    Rails.cache.write(STATE_CACHE_KEY, decision.state)
    Rails.cache.write(SMOOTHED_LOAD_CACHE_KEY, decision.smoothed_load_w)
  end

  def log(decision, load, reading)
    current = load.current_w.nil? ? "stale" : "#{load.current_w.round}W"
    Rails.logger.info(
      "zero_export: state=#{decision.state} target=#{decision.target_w}W load=#{current} " \
      "floor=#{load.floor_w.round}W night_base=#{load.night_base_w.round}W " \
      "soc=#{reading.battery_soc_pct}% temp=#{reading.battery_temperature_c}C pv=#{reading.pv_power_w}W"
    )
  end

  def reset_failures
    Rails.cache.write(FAILURE_COUNT_CACHE_KEY, 0)
  end

  def handle_failure(client, error)
    failures = Rails.cache.read(FAILURE_COUNT_CACHE_KEY).to_i + 1
    Rails.cache.write(FAILURE_COUNT_CACHE_KEY, failures)
    Rails.logger.warn("zero_export: Modbus failure #{failures}/#{MAX_CONSECUTIVE_FAILURES}: #{error.message}")
    return if failures < MAX_CONSECUTIVE_FAILURES

    begin
      client.release_control!
      reset_failures
      Rails.logger.warn("zero_export: relinquished remote control after #{failures} consecutive failures")
    rescue SolakonClient::Error => e
      Rails.logger.warn("zero_export: failed to relinquish remote control: #{e.message}")
    end
  end
end
```

- [ ] **Step 4: Run them to confirm they pass**

Run: `bin/rails test test/jobs/zero_export_tick_job_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/zero_export_tick_job.rb test/jobs/zero_export_tick_job_test.rb
git commit -m "feat: apply Solakon sparse-write control policy"
```

---

## Task 7: Align Spec And Full Verification

**Files:**
- Modify: `docs/superpowers/specs/2026-06-20-solakon-control-algorithm-design.md`

- [ ] **Step 1: Align the design spec with the locked decisions**

Edit the spec so it matches the implementation:

1. **Existing Building Blocks / Open Parameters:** state that algorithm thresholds are **Ruby constants in code** (listed with their owners), and that `solakon.yml` keeps only `host`, `port`, `unit_id`, `monitoring_enabled`, `control_enabled`, `stale_after_s`. Remove the commented YAML knob block from the design narrative.
2. **Temperature section:** rewrite to "thermal protection is the `PROTECTED` state with hysteresis — enter at ≥42.0 °C, leave at ≤41.8 °C. The target follows actual household load but is capped at 400 W; lower output is preferred because less inverter throughput means less internal heat. The Solakon One splits battery↔PV internally; the discharge-current-limit register is not used."
3. **Transitions table:** `any state -> PROTECTED when SoC <= 10% or battery_temp >= 42.0 °C`; `PROTECTED -> ... when SoC >= 11% and battery_temp <= 41.8 °C`. Remove any wording implying temperature is only a cap without a state.
4. **EVENING_CATCH_UP:** note the smoothing is asymmetric — rise is limited to at most `RISE_CAP_W` per tick (slow up), fall takes `FALL_FACTOR` of the gap (fast down) — and the target is clamped to current measured load.
5. **Sun times:** note `SunWindow` uses the next upcoming sunrise for the energy budget and falls back to 06:00/20:00 when no weather location is configured (which keeps the controller in `PV_PRIORITY`-style behavior).

- [ ] **Step 2: Run the focused suite**

```bash
bin/rails test test/solakon_client_test.rb test/models/solakon_reading_test.rb \
  test/jobs/solakon_monitor_job_test.rb test/models/sun_window_test.rb \
  test/models/load_estimate_test.rb test/models/consumption_reader_test.rb \
  test/models/zero_export_controller_test.rb test/jobs/zero_export_tick_job_test.rb
```

Expected: PASS.

- [ ] **Step 3: Run the full suite and static checks**

Run: `bin/rails test`
Run: `bin/rubocop`
Run: `bin/brakeman --quiet`
Expected: all PASS.

- [ ] **Step 4: Review behavior against the spec**

Confirm in code and tests:

```text
SoC <= 10: no intentional battery discharge (PV only).
SoC >= 11: control resumes; no 13/15 recovery band.
Battery >= 42.0C: PROTECTED, follow load capped at 400W, hold until <= 41.8C.
PV-to-house is first priority; daytime discharge only after PV covers what it can.
Evening: rise slow / fall fast, clamped to measured load (export-safe).
Night base: P20 minus 5W reserve, base deadband 15W.
Target never exceeds 800W in any state.
Writes happen on state change, heartbeat (120s), or deadband; otherwise skipped.
Algorithm thresholds are code constants, not solakon.yml.
```

- [ ] **Step 5: Commit any spec wording fix**

```bash
git add docs/superpowers/specs/2026-06-20-solakon-control-algorithm-design.md
git commit -m "docs: align Solakon control spec with implementation"
```

---

## Self-Review

- **Spec coverage:** PV priority (Task 5 `pv_priority_target`), low-SoC protection (Task 2 + 5), thermal protection state with hysteresis and load-following 400 W cap (Task 5 `protected_target`), evening asymmetric smoothing + load clamp (Task 5 `rise_slow_fall_fast`), night base P20 (Task 4), energy budget with correct next sunrise (Task 3 + 5 `enough_for_morning?`), sparse writes + heartbeat (Task 6), temperature storage (Task 1), constants-in-code (Global Constraints + Task 7). No current-limit registers used.
- **Placeholder scan:** no TBD/TODO; every code step shows full code; every test step shows assertions; commands have expected output.
- **Type consistency:** `decide(reading:, load:, sun:, previous_state:, smoothed_load_w:)` matches its callers in Task 5 tests and Task 6 job; `Decision#differs_from?` used in Task 6; `LoadEstimate#effective_w`, `SolakonReading` predicates, `SunWindow#daytime?`/`#hours_until_sunrise`, `ConsumptionReader::NIGHT_BASE_DAYS` all defined where consumed.
- **Carry-over review findings resolved:** next-sunrise correctness (Task 3), night-base caching (Task 6 `night_base_w`), asymmetric smoothing direction fixed (Task 5), weather-missing fallback explicit (Task 3 + 6).
