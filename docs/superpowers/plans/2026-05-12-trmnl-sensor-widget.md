# TRMNL Sensor Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a second TRMNL e-paper widget that shows 2 indoor CO₂ sensors and 1 outdoor sensor with a 3 h trend each, plus two bug fixes (energy-widget timestamp + Turbo broadcast partial paths) that we discovered along the way.

**Architecture:**
- `TrmnlSensorPayloadBuilder` (PORO) shapes a JSON payload from the latest `SensorReading` rows and a 3 h, 15-min-bucket trend per sensor; the existing `SensorPollJob` enqueues `TrmnlSensorPushJob.perform_later` after polling so every push carries fresh data.
- Config moves from a flat `trmnl_webhook_url:` to a nested `trmnl:` block with two URLs (energy + sensors); no backwards-compat shim.
- The Liquid template lives in the repo as the source of truth at `docs/trmnl/sensors.liquid` and uses the real TRMNL framework classes (`view view--full`, `grid grid--cols-3`, `item`, `value`, `label`, `title_bar`).

**Tech Stack:** Rails 8.1, Minitest, SolidQueue, Turbo Streams, Net::HTTP, TRMNL Framework v3.1 (`https://trmnl.com/css/latest/plugins.css`).

**Reference:** `docs/superpowers/specs/2026-05-12-trmnl-sensor-widget-design.md`

---

## File Structure

**Create:**

- `app/models/sensors/reading_presenter.rb` — PORO wrapping a `SensorReading`; centralizes ampel level, battery flag, age label, offline check. One responsibility: turn a raw reading + a "now" timestamp into display-ready primitives.
- `app/models/trmnl_sensor_payload_builder.rb` — Builds the webhook payload (latest values + 3 h trend per sensor). No persistence, no I/O.
- `app/jobs/trmnl_sensor_push_job.rb` — POSTs the payload, mirrors `TrmnlPushJob`. No I/O outside HTTP.
- `docs/trmnl/sensors.liquid` — Source-of-truth Liquid template for the new widget.
- `test/models/test_sensors_reading_presenter.rb`
- `test/models/trmnl_sensor_payload_builder_test.rb`
- `test/jobs/trmnl_sensor_push_job_test.rb`

**Modify:**

- `lib/config_loader.rb` — Replace flat `trmnl_webhook_url` field on `Config` with a `trmnl:` `TrmnlCfg` struct.
- `app/jobs/trmnl_push_job.rb` — Read URL from `config.trmnl&.energy_webhook_url`.
- `app/models/trmnl_payload_builder.rb` — Add pre-formatted `stand` merge variable.
- `docs/trmnl/full.liquid` — Use `{{ stand }}` instead of `{{ ts | date }}`.
- `app/jobs/sensor_poll_job.rb` — Enqueue `TrmnlSensorPushJob.perform_later` before `SensorsBroadcaster.refresh`.
- `app/views/sensors/_dashboard.html.erb` — Qualify the three relative partial renders with `sensors/`.
- `app/helpers/sensors_helper.rb` — Delegate `co2_level` / `battery_low?` / `relative_time` to `Sensors::ReadingPresenter` so the web dashboard and the builder share one source of truth.
- `config/ziwoas.example.yml` — Replace `trmnl_webhook_url` comment block with the new nested example.
- `config/ziwoas.test.yml` — Add the `trmnl:` block with stub URLs.
- `test/test_config_loader.rb` — Replace the three legacy `trmnl_webhook_url` tests with `trmnl:` block tests.
- `test/test_sensors_broadcaster.rb` — Add a test that renders the partial in a controller-less context.
- `test/models/trmnl_payload_builder_test.rb` — Drop `trmnl_webhook_url:` from `Config.new`, switch to `trmnl:`; add a test for `stand`.
- `test/jobs/trmnl_push_job_test.rb` — Same `Config.new` adjustment; URL field path changes.

**Untouched on disk but worth knowing:** `config/recurring.yml` keeps its existing energy schedule and `poll_sensors` entry. No new cron line for the sensor push.

---

## Task 1: Energy widget — pre-format Stand timestamp

**Files:**
- Modify: `app/models/trmnl_payload_builder.rb`
- Modify: `docs/trmnl/full.liquid`
- Modify: `test/models/trmnl_payload_builder_test.rb`

- [ ] **Step 1: Add a failing test for the `stand` merge variable**

Append to `test/models/trmnl_payload_builder_test.rb`:

```ruby
test "build adds a stand string in local time when samples exist" do
  local_now = @tz.utc_to_local(Time.now.utc)
  minute = local_now.min < 30 ? 0 : 30
  slot_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, minute, 0)
  end_ts   = @tz.local_to_utc(slot_floor_local).to_i + 1800
  newest_ts = end_ts - 600
  Sample.create!(plug_id: "bkw", ts: newest_ts, apower_w: 0, aenergy_wh: 0.0)

  payload = TrmnlPayloadBuilder.new(config: @config).build
  expected = @tz.utc_to_local(Time.at(newest_ts)).strftime("%H:%M")
  assert_equal expected, payload["merge_variables"]["stand"]
end

test "build falls back to current local time for stand when no samples exist" do
  Time.stub(:now, Time.utc(2026, 5, 12, 14, 45)) do
    payload = TrmnlPayloadBuilder.new(config: @config).build
    assert_equal "16:45", payload["merge_variables"]["stand"]
  end
end
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
bin/rails test test/models/trmnl_payload_builder_test.rb -n "/stand/"
```

Expected: 2 failures — `stand` key is missing from the hash.

- [ ] **Step 3: Implement `stand` in the builder**

Replace the `build` method in `app/models/trmnl_payload_builder.rb`:

```ruby
def build
  summary    = EnergySummary.new(config: @config).compute_today
  pv_kwh     = (summary.produced_wh.to_f / 1000.0).round(2)
  cons_kwh   = (summary.consumed_wh.to_f / 1000.0).round(2)
  bilanz_kwh = (pv_kwh - cons_kwh).round(2)
  autarky    = (summary.autarky_ratio          * 100).round
  self_use   = (summary.self_consumption_ratio * 100).round
  pv_w, cons_w = power_series
  ts = sample_ts(*window_bounds)

  {
    "merge_variables" => {
      "ts"         => ts,
      "stand"      => @tz.utc_to_local(Time.at(ts)).strftime("%H:%M"),
      "pv_kwh"     => pv_kwh,
      "cons_kwh"   => cons_kwh,
      "bilanz_kwh" => bilanz_kwh,
      "autarky"    => autarky,
      "self_use"   => self_use,
      "pv_w"       => pv_w,
      "cons_w"     => cons_w
    }
  }
end
```

- [ ] **Step 4: Run tests and confirm green**

```bash
bin/rails test test/models/trmnl_payload_builder_test.rb
```

Expected: all tests pass.

- [ ] **Step 5: Update the Liquid template to use `stand`**

In `docs/trmnl/full.liquid`, replace:

```liquid
<span class="instance">Stand {{ ts | date: "%H:%M" }}</span>
```

with:

```liquid
<span class="instance">Stand {{ stand }}</span>
```

- [ ] **Step 6: Commit**

```bash
git add app/models/trmnl_payload_builder.rb docs/trmnl/full.liquid \
        test/models/trmnl_payload_builder_test.rb
git commit -m "Fix TRMNL Stand clock by pre-formatting local time in Ruby"
```

---

## Task 2: SensorsBroadcaster — qualify partial render paths

**Files:**
- Modify: `app/views/sensors/_dashboard.html.erb`
- Modify: `test/test_sensors_broadcaster.rb`

- [ ] **Step 1: Add a failing controller-less render test**

Append to `test/test_sensors_broadcaster.rb`:

```ruby
test "dashboard partial renders cleanly without a controller context" do
  sensor = Struct.new(:id, :name, :type, :room).new("A", "Probe", :meter_pro_co2, nil)
  SensorReading.create!(device_id: "A", taken_at: Time.current,
                        temperature: 22.0, humidity: 40, co2: 600, battery_pct: 80)
  fake_config = Struct.new(:switchbot, :sensors).new(nil, [ sensor ])

  rendered = nil
  SensorsBroadcaster.stub(:load_config, fake_config) do
    WeatherBroadcaster.stub(:broadcast_current, -> { }) do
      Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(_stream, **opts) {
        rendered = ApplicationController.render(partial: opts[:partial], locals: opts[:locals])
      }) do
        SensorsBroadcaster.refresh
      end
    end
  end

  refute_nil rendered, "expected the partial to render"
  assert_includes rendered, "Probe", "expected the sensor card to render its name"
end
```

- [ ] **Step 2: Run the test and confirm it fails with `Missing partial application/_battery_warning`**

```bash
bin/rails test test/test_sensors_broadcaster.rb -n test_dashboard_partial_renders_cleanly_without_a_controller_context
```

Expected: failure with `ActionView::Template::Error: Missing partial application/_battery_warning`.

- [ ] **Step 3: Qualify the three relative renders in the dashboard partial**

Replace the contents of `app/views/sensors/_dashboard.html.erb`:

```erb
<%# app/views/sensors/_dashboard.html.erb %>
<%= turbo_frame_tag "sensors_dashboard" do %>
  <% if latest.empty? %>
    <section class="chart-card empty-state">
      <h2>Noch keine Sensordaten</h2>
      <p>Die Sensoransicht erscheint, sobald die SwitchBot-API Daten geliefert hat.</p>
    </section>
  <% else %>
    <%= render "sensors/battery_warning", sensors: sensors, latest: latest %>
    <section class="sensor-cards">
      <% sensors.each do |s| %>
        <%= render "sensors/card", sensor: s, reading: latest[s.id] %>
      <% end %>
    </section>
    <%= render "sensors/charts" %>
  <% end %>
<% end %>
```

- [ ] **Step 4: Run the broadcaster tests and confirm green**

```bash
bin/rails test test/test_sensors_broadcaster.rb
```

Expected: all 5 tests pass.

- [ ] **Step 5: Run the full controller test for the sensors page to confirm no regression**

```bash
bin/rails test test/controllers/sensors_controller_test.rb
```

Expected: all green. (If the file doesn't exist, run the broader `bin/rails test` once instead.)

- [ ] **Step 6: Commit**

```bash
git add app/views/sensors/_dashboard.html.erb test/test_sensors_broadcaster.rb
git commit -m "Fix SensorsBroadcaster crash by qualifying partial render paths"
```

---

## Task 3: Config migration — `trmnl_webhook_url` → `trmnl:` block

This task touches several files together because the schema change ripples through `ConfigLoader`, `TrmnlPushJob`, the example/test YAML, and three existing test files. Keeping it in one commit prevents an intermediate broken state.

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `app/jobs/trmnl_push_job.rb`
- Modify: `config/ziwoas.example.yml`
- Modify: `config/ziwoas.test.yml`
- Modify: `test/test_config_loader.rb`
- Modify: `test/models/trmnl_payload_builder_test.rb`
- Modify: `test/jobs/trmnl_push_job_test.rb`

- [ ] **Step 1: Add failing tests for the new `trmnl:` block in `ConfigLoader`**

In `test/test_config_loader.rb`, **replace** the three existing `trmnl_webhook_url` tests (the last three `def test_...` blocks in the file) with these:

```ruby
def test_loads_trmnl_block_with_both_urls
  yaml = valid_yaml + <<~YAML
    trmnl:
      energy_webhook_url: https://trmnl.com/api/custom_plugins/energy-uuid
      sensors_webhook_url: https://trmnl.com/api/custom_plugins/sensor-uuid
  YAML
  cfg = load_yaml(yaml)
  assert_equal "https://trmnl.com/api/custom_plugins/energy-uuid",  cfg.trmnl.energy_webhook_url
  assert_equal "https://trmnl.com/api/custom_plugins/sensor-uuid", cfg.trmnl.sensors_webhook_url
end

def test_trmnl_block_defaults_to_nil_urls_when_block_absent
  cfg = load_yaml(valid_yaml)
  refute_nil cfg.trmnl
  assert_nil cfg.trmnl.energy_webhook_url
  assert_nil cfg.trmnl.sensors_webhook_url
end

def test_trmnl_block_accepts_partial_configuration
  yaml = valid_yaml + <<~YAML
    trmnl:
      sensors_webhook_url: https://trmnl.com/api/custom_plugins/only-sensors
  YAML
  cfg = load_yaml(yaml)
  assert_nil cfg.trmnl.energy_webhook_url
  assert_equal "https://trmnl.com/api/custom_plugins/only-sensors", cfg.trmnl.sensors_webhook_url
end

def test_rejects_non_string_trmnl_url
  yaml = valid_yaml + <<~YAML
    trmnl:
      energy_webhook_url: 42
  YAML
  assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
end

def test_rejects_unknown_keys_inside_trmnl_block
  yaml = valid_yaml + <<~YAML
    trmnl:
      bogus: yes
  YAML
  err = assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
  assert_match(/trmnl/i, err.message)
end
```

- [ ] **Step 2: Run config loader tests and confirm failure**

```bash
bin/rails test test/test_config_loader.rb -n "/trmnl/"
```

Expected: failures because `Config` still carries `trmnl_webhook_url` and not a `trmnl` field.

- [ ] **Step 3: Update `ConfigLoader` to expose the nested struct**

In `lib/config_loader.rb`, edit the struct list near the top:

```ruby
PlugCfg     = Struct.new(:id, :name, :role, :ain, :driver, :room, keyword_init: true)
MqttCfg     = Struct.new(:host, :port, :topic_prefix, keyword_init: true)
FritzPollCfg = Struct.new(:active_interval_seconds, :idle_interval_seconds,
                           :idle_threshold_w, :timeout_seconds, keyword_init: true)
FritzBoxCfg = Struct.new(:host, :user, :password, keyword_init: true)
WeatherCfg   = Struct.new(:lat, :lon, keyword_init: true)
SwitchbotCfg = Struct.new(:token, :secret, keyword_init: true)
SensorCfg    = Struct.new(:id, :name, :type, :room, keyword_init: true)
TrmnlCfg     = Struct.new(:energy_webhook_url, :sensors_webhook_url, keyword_init: true)
Config       = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                          :mqtt, :fritz_poll, :plugs, :fritz_box, :weather,
                          :switchbot, :sensors, :trmnl,
                          keyword_init: true)
```

Then replace `build_trmnl_webhook_url` and its call site. Find this block in `build`:

```ruby
trmnl_webhook_url = build_trmnl_webhook_url(@raw["trmnl_webhook_url"])
```

…and change it to:

```ruby
trmnl = build_trmnl(@raw["trmnl"])
```

In the final `Config.new(...)` call, change `trmnl_webhook_url: trmnl_webhook_url,` to `trmnl: trmnl,`.

Replace the helper method `build_trmnl_webhook_url` near the bottom of the file with:

```ruby
ALLOWED_TRMNL_KEYS = %w[energy_webhook_url sensors_webhook_url].freeze

def build_trmnl(h)
  return TrmnlCfg.new(energy_webhook_url: nil, sensors_webhook_url: nil) if h.nil?
  h = require_hash(h, "trmnl")
  unknown = h.keys - ALLOWED_TRMNL_KEYS
  raise Error, "trmnl unknown keys: #{unknown.join(', ')}" if unknown.any?

  TrmnlCfg.new(
    energy_webhook_url:  require_optional_string(h["energy_webhook_url"],  "trmnl.energy_webhook_url"),
    sensors_webhook_url: require_optional_string(h["sensors_webhook_url"], "trmnl.sensors_webhook_url"),
  )
end

def require_optional_string(v, key)
  return nil if v.nil?
  raise Error, "#{key} must be a string" unless v.is_a?(String)
  v
end
```

- [ ] **Step 4: Run config loader tests and confirm green**

```bash
bin/rails test test/test_config_loader.rb
```

Expected: all green.

- [ ] **Step 5: Update `TrmnlPushJob` to read the new path**

In `app/jobs/trmnl_push_job.rb`, change the `perform` method's URL line. Replace:

```ruby
url    = config.trmnl_webhook_url
```

with:

```ruby
url    = config.trmnl&.energy_webhook_url
```

- [ ] **Step 6: Update existing TRMNL tests to use the new struct**

In `test/models/trmnl_payload_builder_test.rb`, change the `setup` block. Replace the `Config.new(...)` call:

```ruby
@config = ConfigLoader::Config.new(
  electricity_price_eur_per_kwh: 0.32,
  timezone: "Europe/Berlin",
  mqtt: mqtt,
  fritz_poll: nil,
  plugs: [ plug_bkw, plug_fridge ],
  fritz_box: nil,
  weather: nil,
  trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: nil, sensors_webhook_url: nil),
)
```

In `test/jobs/trmnl_push_job_test.rb`, replace the `build_config` method:

```ruby
def build_config(energy_webhook_url:)
  plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, ain: nil)
  plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
  mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
  ConfigLoader::Config.new(
    electricity_price_eur_per_kwh: 0.32,
    timezone: "Europe/Berlin",
    mqtt: mqtt,
    fritz_poll: nil,
    plugs: [ plug_bkw, plug_fridge ],
    fritz_box: nil,
    weather: nil,
    trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: energy_webhook_url, sensors_webhook_url: nil),
  )
end
```

Then rename the keyword in the four call sites of `build_config` inside that test file:
- `build_config(trmnl_webhook_url: nil)` → `build_config(energy_webhook_url: nil)`
- `build_config(trmnl_webhook_url: "https://trmnl.com/api/custom_plugins/abc")` → `build_config(energy_webhook_url: "https://trmnl.com/api/custom_plugins/abc")`
- `build_config(trmnl_webhook_url: "https://example/")` → `build_config(energy_webhook_url: "https://example/")` (appears twice)

- [ ] **Step 7: Update YAML fixtures**

In `config/ziwoas.test.yml`, append at the bottom:

```yaml
trmnl:
  energy_webhook_url:  https://example.test/energy
  sensors_webhook_url: https://example.test/sensors
```

In `config/ziwoas.example.yml`, replace the `# trmnl_webhook_url:` comment block with:

```yaml
# Optional: push compact widget data to TRMNL custom plugins.
# Each URL is independent; an absent URL turns its push job into a no-op.
# trmnl:
#   energy_webhook_url:  https://trmnl.com/api/custom_plugins/<energy-uuid>
#   sensors_webhook_url: https://trmnl.com/api/custom_plugins/<sensors-uuid>
```

- [ ] **Step 8: Run the full affected test set**

```bash
bin/rails test test/test_config_loader.rb test/models/trmnl_payload_builder_test.rb \
               test/jobs/trmnl_push_job_test.rb
```

Expected: all green.

- [ ] **Step 9: Commit**

```bash
git add lib/config_loader.rb app/jobs/trmnl_push_job.rb \
        config/ziwoas.example.yml config/ziwoas.test.yml \
        test/test_config_loader.rb test/models/trmnl_payload_builder_test.rb \
        test/jobs/trmnl_push_job_test.rb
git commit -m "Migrate TRMNL config to nested trmnl: block carrying both webhook URLs"
```

---

## Task 4: `Sensors::ReadingPresenter` PORO

Pure-Ruby presenter that turns a `SensorReading` + a "now" timestamp into display-ready primitives. Used by both the web dashboard helper and the new TRMNL payload builder.

**Files:**
- Create: `app/models/sensors/reading_presenter.rb`
- Create: `test/models/test_sensors_reading_presenter.rb`
- Modify: `app/helpers/sensors_helper.rb`

- [ ] **Step 1: Write the failing test file**

Create `test/models/test_sensors_reading_presenter.rb`:

```ruby
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
```

- [ ] **Step 2: Run the test and confirm it fails**

```bash
bin/rails test test/models/test_sensors_reading_presenter.rb
```

Expected: `NameError: uninitialized constant Sensors`.

- [ ] **Step 3: Implement the presenter**

Create `app/models/sensors/reading_presenter.rb`:

```ruby
module Sensors
  class ReadingPresenter
    CO2_WARN_PPM    = 1000
    CO2_BAD_PPM     = 1400
    BATTERY_LOW_PCT = 20
    OFFLINE_AFTER   = 30.minutes

    def initialize(reading, now: Time.current)
      @reading = reading
      @now     = now
    end

    def co2_level
      ppm = @reading&.co2
      return nil if ppm.nil?
      return :bad  if ppm > CO2_BAD_PPM
      return :warn if ppm >= CO2_WARN_PPM
      :good
    end

    def battery_low?
      pct = @reading&.battery_pct
      return false if pct.nil?
      pct <= BATTERY_LOW_PCT
    end

    def age_label
      return "—" if @reading.nil?
      delta = (@now - @reading.taken_at).to_i
      return "vor #{delta} s"       if delta < 60
      return "vor #{delta / 60} Min" if delta < 3600
      "vor #{delta / 3600} h"
    end

    def offline?
      return true if @reading.nil?
      (@now - @reading.taken_at) > OFFLINE_AFTER
    end
  end
end
```

- [ ] **Step 4: Run the test and confirm green**

```bash
bin/rails test test/models/test_sensors_reading_presenter.rb
```

Expected: all 10 tests pass.

- [ ] **Step 5: Delegate `SensorsHelper` to the presenter**

Replace the body of `app/helpers/sensors_helper.rb`:

```ruby
# app/helpers/sensors_helper.rb
module SensorsHelper
  CO2_WARN_PPM    = Sensors::ReadingPresenter::CO2_WARN_PPM
  CO2_BAD_PPM     = Sensors::ReadingPresenter::CO2_BAD_PPM
  BATTERY_LOW_PCT = Sensors::ReadingPresenter::BATTERY_LOW_PCT

  def co2_level(ppm)
    Sensors::ReadingPresenter.new(SensorReading.new(co2: ppm)).co2_level
  end

  def co2_icon_path(level)
    "co2_#{level}.webp"
  end

  def battery_low?(pct)
    Sensors::ReadingPresenter.new(SensorReading.new(battery_pct: pct)).battery_low?
  end

  def relative_time(time)
    return "—" if time.nil?
    Sensors::ReadingPresenter.new(SensorReading.new(taken_at: time)).age_label
  end
end
```

- [ ] **Step 6: Run the sensors-related tests to confirm the helper still works**

```bash
bin/rails test test/test_sensors_broadcaster.rb test/models/test_sensors_reading_presenter.rb
```

Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add app/models/sensors/reading_presenter.rb \
        app/helpers/sensors_helper.rb \
        test/models/test_sensors_reading_presenter.rb
git commit -m "Add Sensors::ReadingPresenter PORO and route helper through it"
```

---

## Task 5: `TrmnlSensorPayloadBuilder`

Builds the JSON payload: an array of sensor objects plus a `stand` clock string. Each sensor object carries latest values, a 3-h trend, and pre-computed `trend_min`/`trend_max` so the Liquid template can normalize the sparkline with two operations per point.

**Files:**
- Create: `app/models/trmnl_sensor_payload_builder.rb`
- Create: `test/models/trmnl_sensor_payload_builder_test.rb`

- [ ] **Step 1: Write the failing test file**

Create `test/models/trmnl_sensor_payload_builder_test.rb`:

```ruby
require "test_helper"

class TrmnlSensorPayloadBuilderTest < ActiveSupport::TestCase
  setup do
    SensorReading.delete_all
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @indoor1 = ConfigLoader::SensorCfg.new(id: "INDOOR1", name: "Wohnzimmer",
                                            type: :meter_pro_co2, room: "Wohnzimmer")
    @indoor2 = ConfigLoader::SensorCfg.new(id: "INDOOR2", name: "Küche",
                                            type: :meter_pro_co2, room: "Küche")
    @outdoor = ConfigLoader::SensorCfg.new(id: "OUTDOOR", name: "Balkon",
                                            type: :outdoor_meter, room: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "h", port: 1, topic_prefix: "p")
    plug = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer, driver: :shelly, ain: nil)
    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32, timezone: "Europe/Berlin",
      mqtt: mqtt, fritz_poll: nil, plugs: [ plug ], fritz_box: nil, weather: nil,
      switchbot: ConfigLoader::SwitchbotCfg.new(token: "t", secret: "s"),
      sensors: [ @indoor1, @indoor2, @outdoor ],
      trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: nil,
                                         sensors_webhook_url: "https://example.test/x")
    )
    @now = Time.utc(2026, 5, 12, 14, 56, 0) # 16:56 Europe/Berlin
  end

  def reading(device_id, taken_at, co2: nil, temp: 20.0, humidity: 40, battery: 80)
    SensorReading.create!(device_id: device_id, taken_at: taken_at,
                          temperature: temp, humidity: humidity, co2: co2, battery_pct: battery)
  end

  test "build returns one sensor entry per configured sensor, in config order" do
    reading("INDOOR1", @now - 4.minutes, co2: 1230, temp: 22.4, humidity: 48)
    reading("INDOOR2", @now - 3.minutes, co2: 740,  temp: 21.8, humidity: 51)
    reading("OUTDOOR", @now - 5.minutes, temp: 12.4, humidity: 64, battery: 73)

    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    sensors = payload.fetch("merge_variables").fetch("sensors")
    assert_equal %w[INDOOR1 INDOOR2 OUTDOOR], sensors.map { |s| s["id"] }
    assert_equal %w[Wohnzimmer Küche Balkon], sensors.map { |s| s["name"] }
    assert_equal %w[indoor indoor outdoor], sensors.map { |s| s["type"] }
  end

  test "indoor sensor exposes ppm primary, ampel and unit" do
    reading("INDOOR1", @now - 4.minutes, co2: 1230, temp: 22.4, humidity: 48)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }

    assert_equal 1230,        s["primary"]
    assert_equal "ppm CO₂",   s["unit"]
    assert_equal "warn",      s["ampel"]
    assert_in_delta 22.4,     s["temperature"], 0.01
    assert_equal 48,          s["humidity"]
    refute s["offline"]
  end

  test "outdoor sensor exposes °C primary, no ampel, single-decimal float" do
    reading("OUTDOOR", @now - 5.minutes, temp: 12.4, humidity: 64)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "OUTDOOR" }

    assert_in_delta 12.4, s["primary"], 0.01
    assert_equal "°C", s["unit"]
    assert_nil s["ampel"]
    assert_equal 64, s["humidity"]
  end

  test "trend has 12 buckets oldest first; newer readings land later than older ones" do
    reading("INDOOR1", @now - 5.minutes,            co2: 1230)
    reading("INDOOR1", @now - 50.minutes,           co2: 950)
    reading("INDOOR1", @now - 2.hours - 10.minutes, co2: 700)

    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert_equal 12, s["trend"].length
    non_null = s["trend"].compact
    assert_includes non_null, 1230
    assert_includes non_null, 700
    # Newest reading should sit later in the array than the oldest.
    assert s["trend"].index(1230) > s["trend"].index(700)
  end

  test "trend buckets without readings are null, not zero" do
    reading("INDOOR1", @now - 5.minutes, co2: 1230)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert_includes s["trend"], nil
    assert_equal 1230, s["trend"].last
  end

  test "trend_min and trend_max bracket the non-null trend values" do
    reading("INDOOR1", @now - 5.minutes, co2: 1230)
    reading("INDOOR1", @now - 50.minutes, co2: 950)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    non_null = s["trend"].compact
    assert_equal non_null.min, s["trend_min"]
    assert_equal non_null.max, s["trend_max"]
  end

  test "age_label is German pre-formatted relative time" do
    reading("INDOOR1", @now - 4.minutes, co2: 800)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert_equal "vor 4 Min", s["age_label"]
  end

  test "battery_low is true at or below 20%" do
    reading("INDOOR1", @now - 1.minute, co2: 800, battery: 14)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert s["battery_low"]
    assert_equal 14, s["battery_pct"]
  end

  test "offline sensor reports offline=true and no trend" do
    reading("INDOOR1", @now - 2.hours, co2: 800) # last reading 2h ago > 30min
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert s["offline"]
    assert_nil s["primary"]
    assert_equal [], s["trend"]
    assert_nil s["ampel"]
  end

  test "completely missing sensor (no rows ever) is offline" do
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert s["offline"]
    assert_nil s["primary"]
  end

  test "stand reflects local time of the most recent reading" do
    reading("INDOOR1", @now - 4.minutes, co2: 1230) # 16:52 local
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    assert_equal "16:52", payload["merge_variables"]["stand"]
  end

  test "stand falls back to current local time when no readings exist" do
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    assert_equal "16:56", payload["merge_variables"]["stand"]
  end

  test "serialized payload stays under the TRMNL 2 kB limit for three sensors with full trend" do
    [ "INDOOR1", "INDOOR2", "OUTDOOR" ].each do |id|
      12.times do |i|
        reading(id, @now - (i * 15).minutes, co2: 800 + i, temp: 20.0 + (i * 0.1))
      end
    end
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    bytes = payload.to_json.bytesize
    assert bytes <= 2048, "payload is #{bytes} B, exceeds 2 kB limit"
  end
end
```

- [ ] **Step 2: Run the tests and confirm failure**

```bash
bin/rails test test/models/trmnl_sensor_payload_builder_test.rb
```

Expected: `NameError: uninitialized constant TrmnlSensorPayloadBuilder`.

- [ ] **Step 3: Implement the builder**

Create `app/models/trmnl_sensor_payload_builder.rb`:

```ruby
class TrmnlSensorPayloadBuilder
  BUCKET_SECONDS = 15 * 60
  BUCKETS        = 12 # 3 hours of 15-min buckets

  def initialize(config:, now: Time.current)
    @config = config
    @now    = now
    @tz     = TZInfo::Timezone.get(config.timezone)
  end

  def build
    sensor_entries = @config.sensors.map { |s| build_sensor_entry(s) }
    stand          = compute_stand(sensor_entries)

    {
      "merge_variables" => {
        "stand"   => stand,
        "sensors" => sensor_entries
      }
    }
  end

  private

  def build_sensor_entry(sensor)
    type      = (sensor.type == :outdoor_meter) ? "outdoor" : "indoor"
    latest    = SensorReading.where(device_id: sensor.id).order(taken_at: :desc).first
    presenter = Sensors::ReadingPresenter.new(latest, now: @now)
    offline   = presenter.offline?

    entry = {
      "id"           => sensor.id,
      "name"         => sensor.name,
      "type"         => type,
      "primary"      => nil,
      "unit"         => (type == "outdoor") ? "°C" : "ppm CO₂",
      "ampel"        => nil,
      "trend"        => [],
      "trend_min"    => nil,
      "trend_max"    => nil,
      "temperature"  => nil,
      "humidity"     => nil,
      "battery_low"  => presenter.battery_low?,
      "battery_pct"  => latest&.battery_pct,
      "age_label"    => presenter.age_label,
      "offline"      => offline,
    }

    return entry if offline

    if type == "outdoor"
      entry["primary"]     = latest.temperature.to_f.round(1)
      entry["temperature"] = entry["primary"]
      entry["humidity"]    = latest.humidity
    else
      entry["primary"]     = latest.co2.to_i
      entry["ampel"]       = presenter.co2_level&.to_s
      entry["temperature"] = latest.temperature.to_f.round(1)
      entry["humidity"]    = latest.humidity
    end

    trend = build_trend(sensor)
    entry["trend"] = trend
    non_null = trend.compact
    entry["trend_min"] = non_null.min
    entry["trend_max"] = non_null.max
    entry
  end

  def build_trend(sensor)
    start_ts, end_ts = window_bounds
    column = (sensor.type == :outdoor_meter) ? :temperature : :co2

    rows = SensorReading
             .where(device_id: sensor.id)
             .where("taken_at >= ? AND taken_at < ?", Time.at(start_ts), Time.at(end_ts))
             .pluck(:taken_at, column)

    buckets = Array.new(BUCKETS) { [] }
    rows.each do |taken_at, value|
      next if value.nil?
      idx = ((taken_at.to_i - start_ts) / BUCKET_SECONDS).to_i
      next if idx < 0 || idx >= BUCKETS
      buckets[idx] << value
    end

    buckets.map do |vals|
      next nil if vals.empty?
      avg = vals.sum.to_f / vals.length
      (column == :temperature) ? avg.round(1) : avg.round
    end
  end

  def window_bounds
    local_now = @tz.utc_to_local(@now.utc)
    quarter   = (local_now.min / 15) * 15
    slot_local = Time.new(local_now.year, local_now.month, local_now.day,
                          local_now.hour, quarter, 0)
    end_ts   = @tz.local_to_utc(slot_local).to_i + BUCKET_SECONDS
    start_ts = end_ts - BUCKETS * BUCKET_SECONDS
    [ start_ts, end_ts ]
  end

  def compute_stand(entries)
    latest_taken_ats = entries.filter_map { |e| sensor_taken_at(e["id"]) }
    latest = latest_taken_ats.max
    return @tz.utc_to_local(@now.utc).strftime("%H:%M") if latest.nil?
    @tz.utc_to_local(latest.utc).strftime("%H:%M")
  end

  def sensor_taken_at(device_id)
    SensorReading.where(device_id: device_id).maximum(:taken_at)
  end
end
```

- [ ] **Step 4: Run the tests and confirm green**

```bash
bin/rails test test/models/trmnl_sensor_payload_builder_test.rb
```

Expected: all 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/models/trmnl_sensor_payload_builder.rb \
        test/models/trmnl_sensor_payload_builder_test.rb
git commit -m "Add TrmnlSensorPayloadBuilder with 3h sparkline trend per sensor"
```

---

## Task 6: `TrmnlSensorPushJob`

Mirrors `TrmnlPushJob` exactly — same logging, same `PayloadTooLarge` guard, same Net::HTTP timeouts. Only the URL field and builder class differ.

**Files:**
- Create: `app/jobs/trmnl_sensor_push_job.rb`
- Create: `test/jobs/trmnl_sensor_push_job_test.rb`

- [ ] **Step 1: Write the failing test file**

Create `test/jobs/trmnl_sensor_push_job_test.rb`:

```ruby
require "test_helper"
require "config_loader"

class TrmnlSensorPushJobTest < ActiveJob::TestCase
  def build_config(sensors_webhook_url:)
    plug = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer, driver: :shelly, ain: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32, timezone: "Europe/Berlin",
      mqtt: mqtt, fritz_poll: nil, plugs: [ plug ], fritz_box: nil, weather: nil,
      sensors: [], switchbot: nil,
      trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: nil,
                                         sensors_webhook_url: sensors_webhook_url),
    )
  end

  def with_config(config)
    original = ConfigLoader.method(:load)
    ConfigLoader.define_singleton_method(:load) { |_path| config }
    yield
  ensure
    ConfigLoader.define_singleton_method(:load, original)
  end

  def stub_builder(payload)
    fake = Object.new
    fake.define_singleton_method(:build) { payload }
    TrmnlSensorPayloadBuilder.stub(:new, ->(**) { fake }) { yield }
  end

  test "does nothing when sensors_webhook_url is not configured" do
    posted = []
    TrmnlSensorPushJob.stub(:post_json, ->(*args) { posted << args; nil }) do
      with_config(build_config(sensors_webhook_url: nil)) do
        TrmnlSensorPushJob.perform_now
      end
    end
    assert_empty posted
  end

  test "POSTs the payload to the configured sensors URL" do
    payload  = { "merge_variables" => { "stand" => "16:56", "sensors" => [] } }
    captured = nil
    stub_builder(payload) do
      TrmnlSensorPushJob.stub(:post_json, ->(url, body) { captured = [ url, body ]; Net::HTTPSuccess.new("1.1", "200", "OK") }) do
        with_config(build_config(sensors_webhook_url: "https://trmnl.com/api/custom_plugins/xyz")) do
          TrmnlSensorPushJob.perform_now
        end
      end
    end
    assert_equal "https://trmnl.com/api/custom_plugins/xyz", captured[0]
    assert_equal payload.to_json, captured[1]
  end

  test "raises when payload exceeds 2 kB" do
    huge = { "merge_variables" => { "blob" => "x" * 4000 } }
    stub_builder(huge) do
      with_config(build_config(sensors_webhook_url: "https://example/")) do
        assert_raises(TrmnlSensorPushJob::PayloadTooLarge) { TrmnlSensorPushJob.perform_now }
      end
    end
  end

  test "logs a warning when the POST fails" do
    payload = { "merge_variables" => { "stand" => "16:56", "sensors" => [] } }
    logs = []
    Rails.logger.stub(:warn, ->(msg) { logs << msg }) do
      stub_builder(payload) do
        TrmnlSensorPushJob.stub(:post_json, ->(*) { raise SocketError, "boom" }) do
          with_config(build_config(sensors_webhook_url: "https://example/")) do
            assert_nothing_raised { TrmnlSensorPushJob.perform_now }
          end
        end
      end
    end
    assert logs.any? { |m| m.to_s.include?("TRMNL sensor push") && m.to_s.include?("boom") }, "expected a TRMNL sensor push warning, got: #{logs.inspect}"
  end
end
```

- [ ] **Step 2: Run the tests and confirm failure**

```bash
bin/rails test test/jobs/trmnl_sensor_push_job_test.rb
```

Expected: `NameError: uninitialized constant TrmnlSensorPushJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/trmnl_sensor_push_job.rb`:

```ruby
require "config_loader"
require "net/http"
require "openssl"
require "uri"
require "json"

class TrmnlSensorPushJob < ApplicationJob
  class PayloadTooLarge < StandardError; end

  MAX_PAYLOAD_BYTES = 2048

  queue_as :default

  def perform
    config = ConfigLoader.load(Rails.root.join("config", config_file_name).to_s)
    url    = config.trmnl&.sensors_webhook_url
    if url.nil? || url.empty?
      Rails.logger.info("TRMNL sensor push skipped (no webhook URL configured)")
      return
    end

    payload = TrmnlSensorPayloadBuilder.new(config: config).build
    body    = payload.to_json
    bytes   = body.bytesize
    if bytes > MAX_PAYLOAD_BYTES
      raise PayloadTooLarge, "TRMNL sensor payload is #{bytes} B, exceeds #{MAX_PAYLOAD_BYTES} B limit"
    end

    begin
      response = self.class.post_json(url, body)
      if response.is_a?(Net::HTTPSuccess)
        Rails.logger.info("TRMNL sensor push: HTTP #{response.code}, #{bytes} B")
      else
        Rails.logger.warn("TRMNL sensor push failed: HTTP #{response.code} #{response.message}")
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => e
      Rails.logger.warn("TRMNL sensor push errored: #{e.class}: #{e.message}")
    end
  end

  def self.post_json(url, body)
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                        open_timeout: 10, read_timeout: 10) do |http|
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req.body = body
      http.request(req)
    end
  end

  private

  def config_file_name
    Rails.env.test? ? "ziwoas.test.yml" : "ziwoas.yml"
  end
end
```

- [ ] **Step 4: Run the tests and confirm green**

```bash
bin/rails test test/jobs/trmnl_sensor_push_job_test.rb
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/trmnl_sensor_push_job.rb test/jobs/trmnl_sensor_push_job_test.rb
git commit -m "Add TrmnlSensorPushJob that POSTs the sensor widget payload"
```

---

## Task 7: Trigger the push from `SensorPollJob`

The push must be enqueued **before** `SensorsBroadcaster.refresh` so a broadcaster exception (we just fixed one but the next is around the corner) cannot prevent the push from landing in the queue.

**Files:**
- Modify: `app/jobs/sensor_poll_job.rb`
- Modify: `test/jobs/sensor_poll_job_test.rb`

- [ ] **Step 1: Add a failing test for the enqueue + ordering**

Append to `test/jobs/sensor_poll_job_test.rb`:

```ruby
test "enqueues the TRMNL sensor push after polling, before broadcast" do
  config = fake_config(
    switchbot: fake_sb(token: "t", secret: "s"),
    sensors: [ fake_sensor("A", :meter_pro_co2) ]
  )
  fake_client = Object.new
  def fake_client.device_status(_)
    { temperature: 1, humidity: 1, co2: 1, battery_pct: 1, firmware_version: "V", raw: {} }
  end

  order = []
  ConfigLoader.stub(:load, config) do
    SwitchBotClient.stub(:new, fake_client) do
      TrmnlSensorPushJob.stub(:perform_later, -> { order << :push }) do
        SensorsBroadcaster.stub(:refresh, -> { order << :broadcast }) do
          SensorPollJob.perform_now
        end
      end
    end
  end

  assert_equal [ :push, :broadcast ], order, "push must be enqueued before the broadcast"
end

test "enqueues the TRMNL sensor push even when the broadcast raises" do
  config = fake_config(
    switchbot: fake_sb(token: "t", secret: "s"),
    sensors: [ fake_sensor("A", :meter_pro_co2) ]
  )
  fake_client = Object.new
  def fake_client.device_status(_)
    { temperature: 1, humidity: 1, co2: 1, battery_pct: 1, firmware_version: "V", raw: {} }
  end

  pushed = false
  ConfigLoader.stub(:load, config) do
    SwitchBotClient.stub(:new, fake_client) do
      TrmnlSensorPushJob.stub(:perform_later, -> { pushed = true }) do
        SensorsBroadcaster.stub(:refresh, -> { raise "broadcast boom" }) do
          assert_raises(RuntimeError) { SensorPollJob.perform_now }
        end
      end
    end
  end

  assert pushed, "push should already be enqueued before the broadcast raises"
end
```

- [ ] **Step 2: Run the tests and confirm failure**

```bash
bin/rails test test/jobs/sensor_poll_job_test.rb -n "/TRMNL sensor push/"
```

Expected: failures because `TrmnlSensorPushJob.perform_later` is never invoked by the job today.

- [ ] **Step 3: Wire the push into the job**

Replace the `perform` method in `app/jobs/sensor_poll_job.rb`:

```ruby
def perform
  config = load_config
  return Rails.logger.info("sensors: not configured") if config.switchbot.nil? || config.sensors.empty?

  client = SwitchBotClient.new(token: config.switchbot.token, secret: config.switchbot.secret)
  now    = Time.current

  config.sensors.each do |sensor|
    begin
      data = client.device_status(sensor.id)
      SensorReading.create!(
        device_id:        sensor.id,
        taken_at:         now,
        temperature:      data[:temperature],
        humidity:         data[:humidity],
        co2:              data[:co2],
        battery_pct:      data[:battery_pct],
        firmware_version: data[:firmware_version],
      )
    rescue SwitchBotClient::Error => e
      Rails.logger.warn("SensorPoll[#{sensor.id}]: #{e.message}")
    end
  end

  TrmnlSensorPushJob.perform_later
  SensorsBroadcaster.refresh
end
```

- [ ] **Step 4: Run the tests and confirm green**

```bash
bin/rails test test/jobs/sensor_poll_job_test.rb
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/sensor_poll_job.rb test/jobs/sensor_poll_job_test.rb
git commit -m "Enqueue TrmnlSensorPushJob from SensorPollJob ahead of broadcast"
```

---

## Task 8: Liquid template `docs/trmnl/sensors.liquid`

Source-of-truth template kept in the repo. The TRMNL plugin UI hosts the executed copy; updates are copy-paste by the operator. No automated test (it's markup with Liquid logic that needs the real TRMNL renderer to verify).

**Files:**
- Create: `docs/trmnl/sensors.liquid`

- [ ] **Step 1: Write the template**

Create `docs/trmnl/sensors.liquid` with this content:

```liquid
{%- comment -%}
  Zipfelmaus Sensoren — TRMNL full layout (800x480).
  Source of truth: docs/trmnl/sensors.liquid in the ziwoas repo.
  Update this file in the repo first, then paste into the TRMNL plugin UI.

  Receives merge_variables:
    stand    — "HH:MM" local-time string (pre-formatted in Ruby)
    sensors  — array of objects:
      id, name, type ("indoor"|"outdoor"),
      primary (Number or null), unit ("ppm CO₂"|"°C"),
      ampel ("good"|"warn"|"bad" or null),
      trend (array of 12 Numbers or nulls, oldest first),
      trend_min, trend_max,
      temperature, humidity, battery_low, battery_pct,
      age_label, offline.
{%- endcomment -%}

<style>
  .ampel-bar { display: inline-flex; gap: 6px; margin-top: 8px; }
  .ampel-bar .seg { width: 56px; height: 18px; border: 2px solid #000; box-sizing: border-box; }
  .ampel-bar .seg.on { background: #000; }
  .ampel-bar.is-hidden { visibility: hidden; }
  .sparkline { display: block; width: 180px; height: 36px; margin: 6px 0 2px; }
  .sparkline polyline { fill: none; stroke: #000; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
  .trmnl .item.align-center .content { align-items: center; text-align: center; }
</style>

<div class="layout layout--col layout--center">
  <div class="grid grid--cols-3 gap--large">
    {%- for s in sensors -%}
      <div class="item align-center">
        <div class="content">
          <span class="label">{{ s.name }}</span>

          {%- if s.offline -%}
            <span class="value value--large">—</span>
            <span class="label">{{ s.unit }}</span>
            <div class="ampel-bar is-hidden"><div class="seg"></div><div class="seg"></div><div class="seg"></div></div>
            <span class="label">keine Daten</span>
            <span class="label">{{ s.age_label }}</span>
          {%- else -%}
            <span class="value value--large">{{ s.primary | replace: ".", "," }}</span>
            <span class="label">{{ s.unit }}</span>

            {%- comment -%} sparkline: map trend → SVG polyline points. {%- endcomment -%}
            {%- assign span = s.trend_max | minus: s.trend_min -%}
            {%- if span == 0 -%}{%- assign span = 1 -%}{%- endif -%}
            {%- capture pts -%}
              {%- for v in s.trend -%}
                {%- assign x = forloop.index0 | times: 15 -%}
                {%- if v == nil -%}{%- continue -%}{%- endif -%}
                {%- assign normy = v | minus: s.trend_min | times: 32 | divided_by: span -%}
                {%- assign y = 36 | minus: normy -%}
                {{ x }},{{ y }}{% unless forloop.last %} {% endunless %}
              {%- endfor -%}
            {%- endcapture -%}
            <svg class="sparkline" viewBox="0 0 180 36" preserveAspectRatio="none">
              <polyline points="{{ pts | strip }}"/>
            </svg>

            {%- if s.ampel -%}
              <div class="ampel-bar">
                <div class="seg on"></div>
                <div class="seg {% if s.ampel != 'good' %}on{% endif %}"></div>
                <div class="seg {% if s.ampel == 'bad' %}on{% endif %}"></div>
              </div>
            {%- else -%}
              <div class="ampel-bar is-hidden"><div class="seg"></div><div class="seg"></div><div class="seg"></div></div>
            {%- endif -%}

            {%- if s.type == "outdoor" -%}
              <span class="label">{{ s.humidity }} % rH</span>
            {%- else -%}
              <span class="label">{{ s.temperature | replace: ".", "," }} °C · {{ s.humidity }} % rH</span>
            {%- endif -%}

            {%- if s.battery_low -%}
              <span class="label">⚠ Batterie {{ s.battery_pct }} %</span>
            {%- endif -%}
            <span class="label">{{ s.age_label }}</span>
          {%- endif -%}
        </div>
      </div>
    {%- endfor -%}
  </div>
</div>

<div class="title_bar">
  <span class="title">Zipfelmaus Sensoren</span>
  <span class="instance">Stand {{ stand }}</span>
</div>
```

- [ ] **Step 2: Run the full test suite to confirm no regression**

```bash
bin/rails test
```

Expected: all tests green.

- [ ] **Step 3: Commit**

```bash
git add docs/trmnl/sensors.liquid
git commit -m "Add Liquid template for TRMNL sensor widget"
```

---

## Post-implementation checklist

These are operator steps the engineer should surface in the PR description but does **not** automate:

1. Update `config/ziwoas.yml` on every deployment to the nested `trmnl:` block (matches `ziwoas.example.yml`). Without the change the existing energy push job becomes a no-op because the old flat key is no longer parsed.
2. Create the new TRMNL custom plugin in the TRMNL UI, paste the contents of `docs/trmnl/sensors.liquid` as the "full" layout, copy the new webhook URL into `trmnl.sensors_webhook_url`.
3. Paste the updated `docs/trmnl/full.liquid` into the existing energy plugin's UI so the Stand-time fix takes effect on the device.

These steps don't have automated tests; verify by hand on first deploy.
