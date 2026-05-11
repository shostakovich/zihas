# TRMNL Energy Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push a compact JSON payload every 15 minutes to a TRMNL custom-plugin webhook so the e-paper device shows today's PV / Bilanz / autarky aggregates plus a rolling-24h stacked hourly bar chart (self-used vs. fed-in Wh).

**Architecture:** A new `TrmnlPayloadBuilder` aggregates the data (existing `EnergySummary` for daily totals + a new rolling-24h hourly bucket calculation), a new `TrmnlPushJob` scheduled via SolidQueue's `recurring.yml` posts the result with `Net::HTTP` to the URL stored as `trmnl_webhook_url` in `config/ziwoas.yml`. The Liquid template that renders the payload on TRMNL is kept in-repo (`docs/trmnl/full.liquid`) and uploaded manually.

**Tech Stack:** Ruby on Rails (Ruby 4.0.x, ActiveJob + SolidQueue), Minitest, `Net::HTTP` for outbound HTTPS, TRMNL Liquid framework. Existing models touched: `ConfigLoader`, `EnergySummary`, `Sample`.

**Reference docs:** [docs/superpowers/specs/2026-05-11-trmnl-energy-widget-design.md](../specs/2026-05-11-trmnl-energy-widget-design.md)

## File map

- Modify `lib/config_loader.rb` — add `trmnl_webhook_url` to the `Config` struct and parse it.
- Modify `test/test_config_loader.rb` — cover the new optional field.
- Modify `config/ziwoas.example.yml` — commented example of the new field.
- Create `app/models/trmnl_payload_builder.rb` — pure-Ruby builder.
- Create `test/models/trmnl_payload_builder_test.rb`.
- Create `app/jobs/trmnl_push_job.rb`.
- Create `test/jobs/trmnl_push_job_test.rb`.
- Modify `config/recurring.yml` — schedule the job every 15 min.
- Create `docs/trmnl/full.liquid` — TRMNL framework template, manually uploaded to the TRMNL UI.

---

## Task 1: Add `trmnl_webhook_url` to ConfigLoader

**Files:**
- Modify: `lib/config_loader.rb:13-15` (Struct definition) and `lib/config_loader.rb:80-112` (`build`)
- Test: `test/test_config_loader.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_config_loader.rb` (before the closing `end` of the class):

```ruby
def test_loads_optional_trmnl_webhook_url
  yaml = valid_yaml + <<~YAML
    trmnl_webhook_url: https://trmnl.com/api/custom_plugins/abc-123
  YAML
  cfg = load_yaml(yaml)
  assert_equal "https://trmnl.com/api/custom_plugins/abc-123", cfg.trmnl_webhook_url
end

def test_trmnl_webhook_url_defaults_to_nil
  cfg = load_yaml(valid_yaml)
  assert_nil cfg.trmnl_webhook_url
end

def test_rejects_non_string_trmnl_webhook_url
  yaml = valid_yaml + <<~YAML
    trmnl_webhook_url: 42
  YAML
  assert_raises(ConfigLoader::Error) { load_yaml(yaml) }
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/test_config_loader.rb`
Expected: 3 failures/errors. The first two fail with `NoMethodError: undefined method 'trmnl_webhook_url'` (Struct does not yet expose the field); the third currently passes silently (it should not) — the rejection test must FAIL until validation is added.

- [ ] **Step 3: Add the field to the Struct and parser**

In `lib/config_loader.rb`, replace the `Config` Struct line:

```ruby
Config      = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                         :mqtt, :fritz_poll, :plugs, :fritz_box, :weather,
                         :trmnl_webhook_url,
                         keyword_init: true)
```

In the `build` method, between the `weather = build_weather(...)` line and the `if plugs.any? ...` block, add:

```ruby
trmnl_webhook_url = build_trmnl_webhook_url(@raw["trmnl_webhook_url"])
```

In the `Config.new(...)` call at the bottom of `build`, add the new keyword:

```ruby
Config.new(
  electricity_price_eur_per_kwh: price,
  timezone:   tz,
  mqtt:       mqtt,
  fritz_poll: fritz_poll,
  plugs:      plugs,
  fritz_box:  fritz_box,
  weather:    weather,
  trmnl_webhook_url: trmnl_webhook_url,
)
```

In the private section (after `build_weather`), add:

```ruby
def build_trmnl_webhook_url(v)
  return nil if v.nil?
  raise Error, "trmnl_webhook_url must be a string" unless v.is_a?(String)
  v
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/test_config_loader.rb`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/config_loader.rb test/test_config_loader.rb
git commit -m "Add optional trmnl_webhook_url to ConfigLoader"
```

---

## Task 2: Document the optional webhook URL in the example config

**Files:**
- Modify: `config/ziwoas.example.yml`

- [ ] **Step 1: Add a commented block to the example**

Append to `config/ziwoas.example.yml` (after the existing `weather:` block; tail of the file is the `plugs:` list — place this *before* `plugs:` to keep the file order parallel to other optional sections, matching the existing `fritz_box:` style):

```yaml
# Optional: push compact widget data to a TRMNL custom plugin.
# When unset (or commented out), the TrmnlPushJob is a no-op.
# trmnl_webhook_url: https://trmnl.com/api/custom_plugins/<your-uuid>
```

- [ ] **Step 2: Run the loader test suite as a sanity check**

Run: `bin/rails test test/test_config_loader.rb`
Expected: all green (no behavioural change, but verifies syntax of the surrounding file is still valid YAML).

- [ ] **Step 3: Commit**

```bash
git add config/ziwoas.example.yml
git commit -m "Document optional trmnl_webhook_url in example config"
```

---

## Task 3: TrmnlPayloadBuilder — today aggregates

**Files:**
- Create: `app/models/trmnl_payload_builder.rb`
- Test: `test/models/trmnl_payload_builder_test.rb`

This task lays down the skeleton and the calendar-day aggregate fields. Hourly buckets come in Task 4.

- [ ] **Step 1: Write the failing test**

Create `test/models/trmnl_payload_builder_test.rb`:

```ruby
require "test_helper"

class TrmnlPayloadBuilderTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      mqtt: mqtt,
      fritz_poll: nil,
      plugs: [ plug_bkw, plug_fridge ],
      fritz_box: nil,
      weather: nil,
      trmnl_webhook_url: nil,
    )
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @midnight_local = @tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
  end

  test "build returns merge_variables hash with today aggregate fields" do
    # 1 kWh produced (BKW counter 0 → 1000 Wh), 0.6 kWh consumed (fridge 500 → 1100 Wh)
    Sample.create!(plug_id: "bkw",    ts: @midnight_local + 60,   apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw",    ts: @midnight_local + 3600, apower_w: 0, aenergy_wh: 1000.0)
    Sample.create!(plug_id: "fridge", ts: @midnight_local + 60,   apower_w: 0, aenergy_wh: 500.0)
    Sample.create!(plug_id: "fridge", ts: @midnight_local + 3600, apower_w: 0, aenergy_wh: 1100.0)

    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")

    assert_in_delta 1.00,  mv["pv_kwh"],     0.001
    assert_in_delta 0.60,  mv["cons_kwh"],   0.001
    assert_in_delta 0.40,  mv["bilanz_kwh"], 0.001
    assert_kind_of Integer, mv["autarky"]
    assert_kind_of Integer, mv["self_use"]
  end

  test "build returns zeros when no samples exist" do
    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")
    assert_equal 0.0, mv["pv_kwh"]
    assert_equal 0.0, mv["cons_kwh"]
    assert_equal 0.0, mv["bilanz_kwh"]
    assert_equal 0,   mv["autarky"]
    assert_equal 0,   mv["self_use"]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb`
Expected: FAIL with `NameError: uninitialized constant TrmnlPayloadBuilder`.

- [ ] **Step 3: Create the builder with today-only fields**

Create `app/models/trmnl_payload_builder.rb`:

```ruby
class TrmnlPayloadBuilder
  def initialize(config:)
    @config = config
  end

  def build
    summary = EnergySummary.new(config: @config).compute_today
    pv_kwh     = (summary.produced_wh.to_f / 1000.0).round(2)
    cons_kwh   = (summary.consumed_wh.to_f / 1000.0).round(2)
    bilanz_kwh = (pv_kwh - cons_kwh).round(2)
    autarky    = (summary.autarky_ratio          * 100).round
    self_use   = (summary.self_consumption_ratio * 100).round

    {
      "merge_variables" => {
        "pv_kwh"     => pv_kwh,
        "cons_kwh"   => cons_kwh,
        "bilanz_kwh" => bilanz_kwh,
        "autarky"    => autarky,
        "self_use"   => self_use,
      },
    }
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb`
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/models/trmnl_payload_builder.rb test/models/trmnl_payload_builder_test.rb
git commit -m "Add TrmnlPayloadBuilder with today aggregate fields"
```

---

## Task 4: TrmnlPayloadBuilder — rolling 24h hourly buckets

**Files:**
- Modify: `app/models/trmnl_payload_builder.rb`
- Test: `test/models/trmnl_payload_builder_test.rb`

The chart on the widget needs two arrays of 24 integers each: `ev` (self-consumed Wh per hour) and `es` (fed-in Wh per hour). Buckets are aligned to local-hour boundaries, oldest first. The implementation mirrors `EnergySummary#compute_self_consumed_wh` (5-minute average-power buckets, overlap = `min(producer_w, consumer_w) * bucket_h`) but groups results into 24 hourly slots.

- [ ] **Step 1: Write the failing test**

Append to `test/models/trmnl_payload_builder_test.rb` (before the final `end`):

```ruby
test "build returns 24 hourly ev/es arrays aligned to local hours" do
  now_utc   = Time.now.utc.to_i
  local_now = @tz.utc_to_local(Time.at(now_utc).utc)
  hour_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
  end_ts   = @tz.local_to_utc(hour_floor_local).to_i + 3600  # upcoming local-hour boundary
  start_ts = end_ts - 86_400

  # Hour bucket index 5 is start_ts + 5*3600 .. start_ts + 6*3600.
  # Drop 60 5-min averaged samples for both plugs in that window:
  bucket_start = start_ts + 5 * 3600
  (0...3600).step(300) do |dt|
    Sample.create!(plug_id: "bkw",    ts: bucket_start + dt, apower_w: 600.0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "fridge", ts: bucket_start + dt, apower_w: 200.0, aenergy_wh: 0.0)
  end

  payload = TrmnlPayloadBuilder.new(config: @config).build
  mv = payload.fetch("merge_variables")

  assert_equal 24, mv["ev"].length
  assert_equal 24, mv["es"].length
  assert(mv["ev"].all? { |v| v.is_a?(Integer) })
  assert(mv["es"].all? { |v| v.is_a?(Integer) })

  # bucket 5: producer 600 W, consumer 200 W → overlap 200 Wh, feed-in 400 Wh
  assert_in_delta 200, mv["ev"][5], 5
  assert_in_delta 400, mv["es"][5], 5

  # all other buckets should be 0
  (0...24).each do |i|
    next if i == 5
    assert_equal 0, mv["ev"][i], "ev bucket #{i}"
    assert_equal 0, mv["es"][i], "es bucket #{i}"
  end
end

test "build returns 24 zero buckets when no samples exist" do
  payload = TrmnlPayloadBuilder.new(config: @config).build
  mv = payload.fetch("merge_variables")
  assert_equal Array.new(24, 0), mv["ev"]
  assert_equal Array.new(24, 0), mv["es"]
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb`
Expected: FAIL with `NoMethodError: undefined method '[]' for nil` (or similar) because `mv["ev"]` is `nil`.

- [ ] **Step 3: Add the hourly bucket computation**

Replace `app/models/trmnl_payload_builder.rb` with:

```ruby
class TrmnlPayloadBuilder
  BUCKET_SECONDS = 300
  HOURS          = 24

  def initialize(config:)
    @config = config
    @tz     = TZInfo::Timezone.get(config.timezone)
  end

  def build
    summary    = EnergySummary.new(config: @config).compute_today
    pv_kwh     = (summary.produced_wh.to_f / 1000.0).round(2)
    cons_kwh   = (summary.consumed_wh.to_f / 1000.0).round(2)
    bilanz_kwh = (pv_kwh - cons_kwh).round(2)
    autarky    = (summary.autarky_ratio          * 100).round
    self_use   = (summary.self_consumption_ratio * 100).round
    ev, es     = hourly_arrays

    {
      "merge_variables" => {
        "pv_kwh"     => pv_kwh,
        "cons_kwh"   => cons_kwh,
        "bilanz_kwh" => bilanz_kwh,
        "autarky"    => autarky,
        "self_use"   => self_use,
        "ev"         => ev,
        "es"         => es,
      },
    }
  end

  private

  def hourly_arrays
    start_ts, end_ts = window_bounds
    rows = bucket_rows(start_ts, end_ts)
    role_by_id = @config.plugs.each_with_object({}) { |p, h| h[p.id] = p.role }

    ev = Array.new(HOURS, 0.0)
    pv = Array.new(HOURS, 0.0)
    rows.group_by { |r| r["bucket_ts"] }.each do |bucket_ts, bucket_rows|
      prod_w = 0.0
      cons_w = 0.0
      bucket_rows.each do |row|
        case role_by_id[row["plug_id"]]
        when :producer then prod_w += row["avg_w"].to_f.abs
        when :consumer then cons_w += row["avg_w"].to_f
        end
      end
      hour_idx = ((bucket_ts - start_ts) / 3600).to_i
      next if hour_idx < 0 || hour_idx >= HOURS

      bucket_h = BUCKET_SECONDS / 3600.0
      pv[hour_idx] += prod_w * bucket_h
      ev[hour_idx] += [ prod_w, cons_w ].min * bucket_h
    end

    ev_int = ev.map(&:round)
    es_int = pv.zip(ev).map { |p, e| [ p - e, 0 ].max.round }
    [ ev_int, es_int ]
  end

  def window_bounds
    now_utc   = Time.now.utc
    local_now = @tz.utc_to_local(now_utc)
    hour_floor = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
    end_ts   = @tz.local_to_utc(hour_floor).to_i + 3600
    start_ts = end_ts - HOURS * 3600
    [ start_ts, end_ts ]
  end

  def bucket_rows(start_ts, end_ts)
    plug_ids = @config.plugs.map(&:id)
    return [] if plug_ids.empty?

    ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL, plug_ids, start_ts, end_ts
          SELECT plug_id,
                 (ts / #{BUCKET_SECONDS}) * #{BUCKET_SECONDS} AS bucket_ts,
                 AVG(apower_w) AS avg_w
            FROM samples
           WHERE plug_id IN (?) AND ts >= ? AND ts < ?
           GROUP BY plug_id, bucket_ts
        SQL
      ])
    ).to_a
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb`
Expected: all four tests pass. If the "bucket 5" assertion is off by a couple of Wh from rounding boundaries, widen the delta to 10 — but anything more than that indicates the index math is wrong.

- [ ] **Step 5: Commit**

```bash
git add app/models/trmnl_payload_builder.rb test/models/trmnl_payload_builder_test.rb
git commit -m "Add rolling-24h hourly ev/es arrays to TrmnlPayloadBuilder"
```

---

## Task 5: TrmnlPayloadBuilder — sample timestamp

**Files:**
- Modify: `app/models/trmnl_payload_builder.rb`
- Test: `test/models/trmnl_payload_builder_test.rb`

`ts` is the unix-seconds timestamp of the most recent `Sample` used in the rolling window — the Liquid template renders it as "Stand HH:MM" in the title bar. When no samples exist, fall back to `Time.now.to_i` so the widget still shows *something* (and so it doesn't lie about freshness from the previous run).

- [ ] **Step 1: Write the failing tests**

Append to `test/models/trmnl_payload_builder_test.rb`:

```ruby
test "build sets ts to the max Sample.ts inside the 24h window" do
  now_utc = Time.now.utc.to_i
  local_now = @tz.utc_to_local(Time.at(now_utc).utc)
  hour_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
  end_ts = @tz.local_to_utc(hour_floor_local).to_i + 3600
  newest_ts = end_ts - 600 # 10 minutes before the upcoming hour boundary
  Sample.create!(plug_id: "bkw", ts: newest_ts, apower_w: 0, aenergy_wh: 0.0)
  Sample.create!(plug_id: "bkw", ts: newest_ts - 3600, apower_w: 0, aenergy_wh: 0.0)

  payload = TrmnlPayloadBuilder.new(config: @config).build
  assert_equal newest_ts, payload["merge_variables"]["ts"]
end

test "build falls back to Time.now.to_i when no samples exist" do
  before = Time.now.to_i
  payload = TrmnlPayloadBuilder.new(config: @config).build
  after = Time.now.to_i
  ts = payload["merge_variables"]["ts"]
  assert ts >= before, "ts (#{ts}) should be ≥ before (#{before})"
  assert ts <= after,  "ts (#{ts}) should be ≤ after (#{after})"
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb`
Expected: FAIL — `ts` is missing from `merge_variables`.

- [ ] **Step 3: Add the `ts` lookup**

In `app/models/trmnl_payload_builder.rb`, inside `build`, add after the `ev, es = hourly_arrays` line:

```ruby
ts = sample_ts(*window_bounds)
```

Change the returned `merge_variables` hash to include `"ts" => ts`:

```ruby
"merge_variables" => {
  "ts"         => ts,
  "pv_kwh"     => pv_kwh,
  "cons_kwh"   => cons_kwh,
  "bilanz_kwh" => bilanz_kwh,
  "autarky"    => autarky,
  "self_use"   => self_use,
  "ev"         => ev,
  "es"         => es,
},
```

Add a private method below `bucket_rows`:

```ruby
def sample_ts(start_ts, end_ts)
  plug_ids = @config.plugs.map(&:id)
  return Time.now.to_i if plug_ids.empty?

  max_ts = Sample.where(plug_id: plug_ids, ts: start_ts...end_ts).maximum(:ts)
  max_ts || Time.now.to_i
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/models/trmnl_payload_builder.rb test/models/trmnl_payload_builder_test.rb
git commit -m "Include sample timestamp in TrmnlPayloadBuilder output"
```

---

## Task 6: Assert payload fits in 2 kB

**Files:**
- Test: `test/models/trmnl_payload_builder_test.rb`

Pure-defence test: ensures a realistic payload encodes to ≤ 2 048 bytes of JSON. If anyone later adds a field that pushes us over the TRMNL webhook limit, this test catches it.

- [ ] **Step 1: Write the test**

Append to `test/models/trmnl_payload_builder_test.rb`:

```ruby
test "serialized payload stays under TRMNL's 2 kB webhook limit" do
  now_utc = Time.now.utc.to_i
  local_now = @tz.utc_to_local(Time.at(now_utc).utc)
  hour_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
  end_ts = @tz.local_to_utc(hour_floor_local).to_i + 3600
  start_ts = end_ts - 86_400

  # Fill every 5-min slot of every hour with realistic-magnitude values.
  (start_ts...end_ts).step(300) do |t|
    Sample.create!(plug_id: "bkw",    ts: t, apower_w: 999.0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "fridge", ts: t, apower_w: 999.0, aenergy_wh: 0.0)
  end

  payload = TrmnlPayloadBuilder.new(config: @config).build
  bytes = payload.to_json.bytesize
  assert bytes <= 2048, "payload is #{bytes} B, exceeds TRMNL's 2 kB limit"
end
```

- [ ] **Step 2: Run the test**

Run: `bin/rails test test/models/trmnl_payload_builder_test.rb -n test_serialized_payload_stays_under_TRMNL_s_2_kB_webhook_limit`
Expected: PASS. If it fails, the failing line tells you the actual byte count — the design has ~1.5 kB headroom so a fail means a structural regression to investigate before continuing.

- [ ] **Step 3: Commit**

```bash
git add test/models/trmnl_payload_builder_test.rb
git commit -m "Guard TrmnlPayloadBuilder output against TRMNL 2 kB webhook limit"
```

---

## Task 7: TrmnlPushJob

**Files:**
- Create: `app/jobs/trmnl_push_job.rb`
- Test: `test/jobs/trmnl_push_job_test.rb`

The job is intentionally simple: load the config from disk (same pattern `AggregatorJob` uses), no-op when the URL is absent, otherwise build the payload and POST it. No ActiveJob retries — the next 15-min run is the retry.

- [ ] **Step 1: Write the failing tests**

Create `test/jobs/trmnl_push_job_test.rb`:

```ruby
require "test_helper"
require "config_loader"

class TrmnlPushJobTest < ActiveJob::TestCase
  def build_config(trmnl_webhook_url:)
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
      trmnl_webhook_url: trmnl_webhook_url,
    )
  end

  def with_config(config)
    original = ConfigLoader.method(:load)
    ConfigLoader.define_singleton_method(:load) { |_path| config }
    yield
  ensure
    ConfigLoader.define_singleton_method(:load, original)
  end

  test "does nothing when trmnl_webhook_url is not configured" do
    posted = []
    TrmnlPushJob.stub(:post_json, ->(*args) { posted << args }) do
      with_config(build_config(trmnl_webhook_url: nil)) do
        TrmnlPushJob.perform_now
      end
    end
    assert_empty posted
  end

  test "POSTs the payload as JSON to the configured URL" do
    payload  = { "merge_variables" => { "ts" => 1, "pv_kwh" => 0 } }
    captured = nil
    TrmnlPayloadBuilder.stub(:new, ->(**) { Struct.new(:b).new.tap { |s| s.define_singleton_method(:build) { payload } } }) do
      TrmnlPushJob.stub(:post_json, ->(url, body) { captured = [ url, body ]; Net::HTTPSuccess.new("1.1", "200", "OK") }) do
        with_config(build_config(trmnl_webhook_url: "https://trmnl.com/api/custom_plugins/abc")) do
          TrmnlPushJob.perform_now
        end
      end
    end
    assert_equal "https://trmnl.com/api/custom_plugins/abc", captured[0]
    assert_equal payload.to_json, captured[1]
  end

  test "raises when payload exceeds 2 kB" do
    huge = { "merge_variables" => { "blob" => "x" * 4000 } }
    TrmnlPayloadBuilder.stub(:new, ->(**) { Struct.new(:b).new.tap { |s| s.define_singleton_method(:build) { huge } } }) do
      with_config(build_config(trmnl_webhook_url: "https://example/")) do
        assert_raises(TrmnlPushJob::PayloadTooLarge) { TrmnlPushJob.perform_now }
      end
    end
  end

  test "logs a warning when the POST fails" do
    payload = { "merge_variables" => { "ts" => 1 } }
    logs = []
    Rails.logger.stub(:warn, ->(msg) { logs << msg }) do
      TrmnlPayloadBuilder.stub(:new, ->(**) { Struct.new(:b).new.tap { |s| s.define_singleton_method(:build) { payload } } }) do
        TrmnlPushJob.stub(:post_json, ->(*) { raise SocketError, "boom" }) do
          with_config(build_config(trmnl_webhook_url: "https://example/")) do
            assert_nothing_raised { TrmnlPushJob.perform_now }
          end
        end
      end
    end
    assert logs.any? { |m| m.to_s.include?("TRMNL push") && m.to_s.include?("boom") }, "expected a TRMNL push warning, got: #{logs.inspect}"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/jobs/trmnl_push_job_test.rb`
Expected: FAIL with `NameError: uninitialized constant TrmnlPushJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/trmnl_push_job.rb`:

```ruby
require "config_loader"
require "net/http"
require "uri"
require "json"

class TrmnlPushJob < ApplicationJob
  class PayloadTooLarge < StandardError; end

  MAX_PAYLOAD_BYTES = 2048

  queue_as :default

  def perform
    config = ConfigLoader.load(Rails.root.join("config", config_file_name).to_s)
    url    = config.trmnl_webhook_url
    if url.nil? || url.empty?
      Rails.logger.info("TRMNL push skipped (no webhook URL configured)")
      return
    end

    payload = TrmnlPayloadBuilder.new(config: config).build
    body    = payload.to_json
    bytes   = body.bytesize
    if bytes > MAX_PAYLOAD_BYTES
      raise PayloadTooLarge, "TRMNL payload is #{bytes} B, exceeds #{MAX_PAYLOAD_BYTES} B limit"
    end

    response = self.class.post_json(url, body)
    if response.is_a?(Net::HTTPSuccess)
      Rails.logger.info("TRMNL push: HTTP #{response.code}, #{bytes} B")
    else
      Rails.logger.warn("TRMNL push failed: HTTP #{response.code} #{response.message}")
    end
  rescue StandardError => e
    raise if e.is_a?(PayloadTooLarge)
    Rails.logger.warn("TRMNL push errored: #{e.class}: #{e.message}")
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

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test test/jobs/trmnl_push_job_test.rb`
Expected: all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/trmnl_push_job.rb test/jobs/trmnl_push_job_test.rb
git commit -m "Add TrmnlPushJob that POSTs the widget payload to TRMNL"
```

---

## Task 8: Schedule the push job every 15 minutes

**Files:**
- Modify: `config/recurring.yml`

- [ ] **Step 1: Add the entry**

In `config/recurring.yml`, inside the `aggregator_schedule` anchor (between the existing `fetch_current_weather` and `fetch_today_weather` blocks is fine, since both are 15-min jobs — placement is cosmetic), add:

```yaml
  push_trmnl_widget:
    class: TrmnlPushJob
    queue: default
    schedule: every 15 minutes
```

- [ ] **Step 2: Sanity-load the YAML**

Run: `bin/rails runner 'puts YAML.load_file(Rails.root.join("config/recurring.yml")).dig("development", "push_trmnl_widget", "class")'`
Expected output: `TrmnlPushJob`

- [ ] **Step 3: Run the whole test suite**

Run: `bin/rails test`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add config/recurring.yml
git commit -m "Schedule TrmnlPushJob every 15 minutes"
```

---

## Task 9: Liquid template

**Files:**
- Create: `docs/trmnl/full.liquid`

This file is the source of truth for the TRMNL plugin's Liquid template. It is pasted into the TRMNL plugin UI manually after each meaningful change. It is not loaded by Rails — keeping it in-repo just gives us versioning and code review.

The template uses TRMNL framework classes (`layout`, `columns`, `title_bar`, `value`, `label`, `value--xxlarge`, etc.). The bar chart is hand-rolled in SVG because the framework does not ship a stacked-bar primitive.

- [ ] **Step 1: Create the file**

Create `docs/trmnl/full.liquid` with the following contents:

```liquid
{%- comment -%}
  Zipfelmaus Energie — TRMNL full layout (800x480).
  Source of truth: docs/trmnl/full.liquid in the ziwoas repo.
  Update this file in the repo first, then paste into the TRMNL plugin UI.

  Receives merge_variables: ts, pv_kwh, cons_kwh, bilanz_kwh, autarky, self_use, ev[24], es[24]
{%- endcomment -%}

{%- assign max_h = 0 -%}
{%- for i in (0..23) -%}
  {%- assign total = ev[i] | plus: es[i] -%}
  {%- if total > max_h -%}{%- assign max_h = total -%}{%- endif -%}
{%- endfor -%}
{%- if max_h == 0 -%}{%- assign max_h = 1 -%}{%- endif -%}

<div class="layout layout--col gap--small">
  <!-- Hero row -->
  <div class="grid grid--cols-2">
    <div>
      <span class="label">PV heute</span>
      <span class="value value--xxlarge">{{ pv_kwh | replace: ".", "," }} <span class="unit">kWh</span></span>
    </div>
    <div class="text--right">
      <span class="label">Bilanz heute</span>
      <span class="value value--xlarge">
        {%- if bilanz_kwh > 0 -%}+{%- endif -%}
        {{ bilanz_kwh | replace: ".", "," }} <span class="unit">kWh</span>
      </span>
    </div>
  </div>

  <!-- 24h stacked bar chart -->
  <svg viewBox="0 0 720 180" width="100%" preserveAspectRatio="none">
    <defs>
      <pattern id="hatch" patternUnits="userSpaceOnUse" width="3" height="3" patternTransform="rotate(45)">
        <line x1="0" y1="0" x2="0" y2="3" stroke="black" stroke-width="1"/>
      </pattern>
    </defs>
    <line x1="0" y1="160" x2="720" y2="160" stroke="black" stroke-width="0.6"/>
    {%- for i in (0..23) -%}
      {%- assign x  = i | times: 30 -%}
      {%- assign ev_h = ev[i] | times: 150 | divided_by: max_h -%}
      {%- assign es_h = es[i] | times: 150 | divided_by: max_h -%}
      {%- assign ev_y = 160 | minus: ev_h -%}
      {%- assign es_y = ev_y | minus: es_h -%}
      {%- if ev_h > 0 -%}
        <rect x="{{ x | plus: 2 }}" y="{{ ev_y }}" width="26" height="{{ ev_h }}" fill="black"/>
      {%- else -%}
        <rect x="{{ x | plus: 2 }}" y="158" width="26" height="2" fill="black" fill-opacity="0.25"/>
      {%- endif -%}
      {%- if es_h > 0 -%}
        <rect x="{{ x | plus: 2 }}" y="{{ es_y }}" width="26" height="{{ es_h }}" fill="url(#hatch)" stroke="black" stroke-width="0.5"/>
      {%- endif -%}
    {%- endfor -%}
    <text x="0"   y="176" font-size="10">−24 h</text>
    <text x="160" y="176" font-size="10">−18 h</text>
    <text x="340" y="176" font-size="10">−12 h</text>
    <text x="520" y="176" font-size="10">−6 h</text>
    <text x="670" y="176" font-size="10">jetzt</text>
    <g transform="translate(440, 4)" font-size="10">
      <rect x="0" y="0" width="9" height="9" fill="black"/>
      <text x="12" y="9">Eigenverbrauch</text>
      <rect x="120" y="0" width="9" height="9" fill="url(#hatch)" stroke="black" stroke-width="0.5"/>
      <text x="132" y="9">Einspeisung</text>
    </g>
  </svg>

  <!-- Footer row -->
  <div class="grid grid--cols-3">
    <div><span class="label">Verbraucht heute</span><span class="value value--large">{{ cons_kwh | replace: ".", "," }} <span class="unit">kWh</span></span></div>
    <div><span class="label">Autarkie</span><span class="value value--large">{{ autarky }} %</span></div>
    <div><span class="label">Eigenverbrauch</span><span class="value value--large">{{ self_use }} %</span></div>
  </div>
</div>

<div class="title_bar">
  <span class="title">Zipfelmaus Energie</span>
  <span class="instance">Stand {{ ts | date: "%H:%M" }}</span>
</div>
```

- [ ] **Step 2: Commit**

```bash
git add docs/trmnl/full.liquid
git commit -m "Add TRMNL Liquid template for the Zipfelmaus full widget"
```

- [ ] **Step 3: Manual deployment note**

After merging, the operator pastes the contents of `docs/trmnl/full.liquid` into the TRMNL plugin UI's "Markup" editor for the `full` layout. The framework's class names (`layout`, `grid`, `value`, etc.) are interpreted by TRMNL's renderer; if any of them have evolved between framework versions, the visual output will differ from the mockup. This is the agreed manual sync step — no automation in this iteration.

---

## Final verification

- [ ] Run the full suite: `bin/rails test`
- [ ] Boot the dev stack and let SolidQueue pick up the new schedule: `bin/dev`
- [ ] In the SolidQueue logs, confirm that within 15 minutes you see a `"TRMNL push: HTTP 200, NNN B"` line (or `"TRMNL push skipped"` if you didn't configure the URL locally).
- [ ] Visit the TRMNL plugin page in your browser and force-refresh the device; the widget should render the latest payload.
