# Autarkie- & Eigenverbrauchsquote Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Autarkiequote (self-sufficiency) and Eigenverbrauchsquote (self-consumption) metrics, surfaced live on the dashboard for today and aggregated/charted on the reports page across the selected range.

**Architecture:** A new `daily_energy_summary` table stores per-day cross-plug totals (`produced_wh`, `consumed_wh`, `self_consumed_wh`) where `self_consumed_wh = ∫ min(Σproducer_w, Σconsumer_w) dt` integrated at 5-min resolution. A pure-Ruby `DailyEnergySummaryBuilder` computes the row from `samples_5min`; the nightly `Aggregator` calls it after writing 5-min/daily aggregates. A one-shot data migration backfills existing days. `EnergyReport` reads daily totals + ratios from the new table; `EnergySummary` adds the same metric for "today" by ad-hoc 5-min bucketing of raw `samples`.

**Tech Stack:** Ruby on Rails 8.1 (SQLite), Minitest, Stimulus + Chart.js.

---

## Spec

`docs/superpowers/specs/2026-05-06-autarky-self-consumption-design.md`

---

## File Structure

**New files:**
- `db/migrate/20260506000000_create_daily_energy_summary.rb` — schema migration
- `db/migrate/20260506000001_backfill_daily_energy_summary.rb` — one-shot data migration
- `app/models/daily_energy_summary.rb` — AR model (uses singular table name `daily_energy_summary` to match spec, like `Sample5min`)
- `lib/daily_energy_summary_builder.rb` — pure computation class
- `test/lib/test_daily_energy_summary_builder.rb` — unit tests for builder
- `test/models/daily_energy_summary_test.rb` — AR sanity tests

**Modified files:**
- `lib/aggregator.rb` — call builder after `aggregate_day` work
- `app/models/energy_summary.rb` — add `self_consumed_wh`, expose `autarky_ratio`, `self_consumption_ratio`
- `app/views/api/today_summary.json.jbuilder` — emit new fields
- `app/views/dashboard/index.html.erb` — two new "heute" tiles
- `app/javascript/controllers/dashboard_controller.js` — wire up the new tiles
- `app/models/energy_report.rb` — load `DailyEnergySummary`, replace per-plug daily fold with summary lookup, add ratio aggregates and chart payload
- `app/views/reports/index.html.erb` — two new tiles + ratios chart canvas
- `app/javascript/controllers/energy_report_controller.js` — render ratios line chart
- `test/test_aggregator.rb` — verify summary row written
- `test/models/energy_summary_test.rb` — verify `self_consumed_wh` and ratios
- `test/models/energy_report_test.rb` — verify summary tiles + chart payload come from new table
- `test/controllers/api_controller_test.rb` — verify new JSON fields
- `test/controllers/reports_controller_test.rb` — verify new tiles labels and section label
- `test/controllers/dashboard_controller_test.rb` — verify new tile labels appear in HTML
- `db/schema.rb` — auto-updated by migration

---

## Conventions Used By This Codebase (read before starting)

- **Tests:** Minitest, run with `bin/rails test`. Run a single file with `bin/rails test test/path/to/file.rb`. Tests under `test/lib/` (existing files like `test/test_aggregator.rb` are at top level — keep that pattern for `lib/` tests).
- **Model patterns:** `Sample5min` uses `self.table_name = "samples_5min"` to keep a singular table name — `DailyEnergySummary` follows the same idiom.
- **No new gems** are added by this plan.
- **Migration timestamps** in this repo use millisecond-zero format (`YYYYMMDDhhmmss` → e.g. `20260506000000`). Use a date-suffix that sorts after existing migrations (latest is `20260504000000`).
- **Formatting in views:** German number format (decimal comma, no thousand separator) via `number_with_precision(value, precision: 2, delimiter: ".", separator: ",")`.
- **JS controllers:** Stimulus targets are camelCase in JS but `data-controller-target="kebabCase"` would be wrong — existing convention uses camelCase target names like `tileProduced`. Match it exactly.
- **DRY for tests:** the existing `test/models/energy_report_test.rb` uses a `seed_daily` helper. Where new tests need `samples_5min` rows, they should write a small helper too.

---

## Task 1: Migration — create `daily_energy_summary` table

**Files:**
- Create: `db/migrate/20260506000000_create_daily_energy_summary.rb`

- [ ] **Step 1: Write the migration**

```ruby
class CreateDailyEnergySummary < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_energy_summary, primary_key: :date, id: false do |t|
      t.string :date, null: false
      t.float  :produced_wh, null: false
      t.float  :consumed_wh, null: false
      t.float  :self_consumed_wh, null: false
    end
  end
end
```

- [ ] **Step 2: Apply the migration in dev and test**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate`
Expected: migration runs, no errors. `db/schema.rb` updated.

- [ ] **Step 3: Sanity-check the schema dump**

Run: `grep -A5 "daily_energy_summary" db/schema.rb`
Expected: shows the table with the four columns and `date` as primary key.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/20260506000000_create_daily_energy_summary.rb db/schema.rb
git commit -m "Add daily_energy_summary table"
```

---

## Task 2: AR model `DailyEnergySummary` + sanity tests

**Files:**
- Create: `app/models/daily_energy_summary.rb`
- Create: `test/models/daily_energy_summary_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/daily_energy_summary_test.rb`
Expected: FAIL with `NameError: uninitialized constant DailyEnergySummary`.

- [ ] **Step 3: Write minimal implementation**

```ruby
class DailyEnergySummary < ApplicationRecord
  self.table_name = "daily_energy_summary"
  self.primary_key = :date

  validates :date, presence: true,
                   format: { with: /\A\d{4}-\d{2}-\d{2}\z/, message: "must be YYYY-MM-DD" }
  validates :produced_wh, :consumed_wh, :self_consumed_wh,
            presence: true, numericality: true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/models/daily_energy_summary_test.rb`
Expected: 2 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/models/daily_energy_summary.rb test/models/daily_energy_summary_test.rb
git commit -m "Add DailyEnergySummary model"
```

---

## Task 3: `DailyEnergySummaryBuilder` — pure computation

The builder reads `samples_5min` for a given day and a given list of plugs (with roles), and returns `{ produced_wh:, consumed_wh:, self_consumed_wh: }`. No DB writes here — that belongs to the caller.

**Files:**
- Create: `lib/daily_energy_summary_builder.rb`
- Create: `test/lib/test_daily_energy_summary_builder.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"
require "daily_energy_summary_builder"

class DailyEnergySummaryBuilderTest < ActiveSupport::TestCase
  setup do
    Sample5min.delete_all
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "pv",     name: "PV",      role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "desk",   name: "Desk",    role: :consumer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "washer", name: "Washer",  role: :consumer, driver: :shelly, ain: nil)
    ]
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @date = "2026-04-10"
    @midnight = @tz.local_to_utc(Time.parse("#{@date} 00:00:00")).to_i
  end

  def write_5min(plug_id:, offset_min:, avg_w:)
    Sample5min.create!(
      plug_id: plug_id,
      bucket_ts: @midnight + offset_min * 60,
      avg_power_w: avg_w,
      energy_delta_wh: avg_w * 300.0 / 3600.0,
      sample_count: 1
    )
  end

  test "returns zero for a day with no buckets" do
    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)
    assert_in_delta 0.0, result.fetch(:produced_wh)
    assert_in_delta 0.0, result.fetch(:consumed_wh)
    assert_in_delta 0.0, result.fetch(:self_consumed_wh)
  end

  test "consumer-only day yields zero self-consumption" do
    write_5min(plug_id: "desk", offset_min: 0, avg_w: 100)
    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)
    assert_in_delta 0.0,           result.fetch(:produced_wh)
    assert_in_delta 100.0 * 5/60.0, result.fetch(:consumed_wh)
    assert_in_delta 0.0,           result.fetch(:self_consumed_wh)
  end

  test "producer-only day yields zero self-consumption" do
    write_5min(plug_id: "pv", offset_min: 0, avg_w: 200)
    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)
    assert_in_delta 200.0 * 5/60.0, result.fetch(:produced_wh)
    assert_in_delta 0.0,           result.fetch(:consumed_wh)
    assert_in_delta 0.0,           result.fetch(:self_consumed_wh)
  end

  test "self-consumption is min of producer and consumer per bucket" do
    # Bucket A: PV 200 W, load 100 W -> self-consumed 100 W (load fully covered)
    # Bucket B: PV 50 W,  load 300 W -> self-consumed  50 W (PV fully consumed)
    write_5min(plug_id: "pv",   offset_min: 0,  avg_w: 200)
    write_5min(plug_id: "desk", offset_min: 0,  avg_w: 100)
    write_5min(plug_id: "pv",   offset_min: 5,  avg_w:  50)
    write_5min(plug_id: "desk", offset_min: 5,  avg_w: 300)

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    bucket_h = 5.0 / 60.0
    assert_in_delta (200 + 50) * bucket_h, result.fetch(:produced_wh)
    assert_in_delta (100 + 300) * bucket_h, result.fetch(:consumed_wh)
    assert_in_delta (100 +  50) * bucket_h, result.fetch(:self_consumed_wh)
  end

  test "sums multiple consumers per bucket before taking the min" do
    write_5min(plug_id: "pv",     offset_min: 0, avg_w: 250)
    write_5min(plug_id: "desk",   offset_min: 0, avg_w: 100)
    write_5min(plug_id: "washer", offset_min: 0, avg_w: 200)

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    bucket_h = 5.0 / 60.0
    assert_in_delta 250 * bucket_h, result.fetch(:produced_wh)
    assert_in_delta 300 * bucket_h, result.fetch(:consumed_wh)
    # producer = 250, consumer total = 300, min = 250
    assert_in_delta 250 * bucket_h, result.fetch(:self_consumed_wh)
  end

  test "ignores buckets outside the requested local day" do
    write_5min(plug_id: "pv",   offset_min: 0,         avg_w: 200)
    write_5min(plug_id: "desk", offset_min: 0,         avg_w: 100)
    # one bucket on the next local day
    write_5min(plug_id: "pv",   offset_min: 24 * 60,   avg_w: 999)

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    bucket_h = 5.0 / 60.0
    assert_in_delta 200 * bucket_h, result.fetch(:produced_wh)
    assert_in_delta 100 * bucket_h, result.fetch(:consumed_wh)
    assert_in_delta 100 * bucket_h, result.fetch(:self_consumed_wh)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/test_daily_energy_summary_builder.rb`
Expected: FAIL with `LoadError: cannot load such file -- daily_energy_summary_builder`.

- [ ] **Step 3: Write the implementation**

```ruby
require "date"
require "tzinfo"

class DailyEnergySummaryBuilder
  BUCKET_SECONDS = 300

  def initialize(plugs:, timezone:)
    @plug_role = plugs.each_with_object({}) { |p, h| h[p.id] = p.role }
    @timezone  = timezone.is_a?(TZInfo::Timezone) ? timezone : TZInfo::Timezone.get(timezone)
  end

  def build(date_s)
    start_ts = @timezone.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i
    end_ts   = start_ts + 86_400

    rows = Sample5min.where(bucket_ts: start_ts..(end_ts - 1)).to_a
    bucket_h = BUCKET_SECONDS / 3600.0

    produced_wh      = 0.0
    consumed_wh      = 0.0
    self_consumed_wh = 0.0

    rows.group_by(&:bucket_ts).each_value do |bucket_rows|
      prod_w = 0.0
      cons_w = 0.0
      bucket_rows.each do |row|
        case @plug_role[row.plug_id]
        when :producer then prod_w += row.avg_power_w
        when :consumer then cons_w += row.avg_power_w
        end
      end
      produced_wh      += prod_w * bucket_h
      consumed_wh      += cons_w * bucket_h
      self_consumed_wh += [ prod_w, cons_w ].min * bucket_h
    end

    {
      produced_wh:      produced_wh,
      consumed_wh:      consumed_wh,
      self_consumed_wh: self_consumed_wh
    }
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/test_daily_energy_summary_builder.rb`
Expected: 6 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/daily_energy_summary_builder.rb test/lib/test_daily_energy_summary_builder.rb
git commit -m "Add DailyEnergySummaryBuilder"
```

---

## Task 4: Hook builder into `Aggregator#aggregate_day`

The aggregator currently writes `samples_5min` and `daily_totals` inside one transaction. We add the summary upsert at the end of the same transaction so the row is consistent with the freshly written 5-min data and remains idempotent.

**Files:**
- Modify: `lib/aggregator.rb`
- Modify: `test/test_aggregator.rb`

The aggregator currently has no plug list — it operates purely on `samples`. The builder needs plug roles. We pass the plugs in via the constructor (additive, default `nil` to keep existing tests passing).

- [ ] **Step 1: Write the failing test**

Add this test at the bottom of `test/test_aggregator.rb`, before the final `end`:

```ruby
  test "aggregate_day writes daily_energy_summary row" do
    plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    ]
    aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7, plugs: plugs)

    start_ts = berlin_midnight_utc("2026-04-10")
    # PV 200 W, fridge 100 W simultaneously over 1h via 12 minute samples
    (0..3600).step(60) do |dt|
      Sample.create!(plug_id: "bkw",    ts: start_ts + dt, apower_w: 200.0, aenergy_wh: 200.0 * dt / 3600.0)
      Sample.create!(plug_id: "fridge", ts: start_ts + dt, apower_w: 100.0, aenergy_wh: 100.0 * dt / 3600.0)
    end

    aggregator.aggregate_day("2026-04-10")

    summary = DailyEnergySummary.find("2026-04-10")
    # 1 hour of overlap: 200 W producer, 100 W consumer -> 100 Wh self-consumed
    assert_in_delta 200.0, summary.produced_wh,      1.0
    assert_in_delta 100.0, summary.consumed_wh,      1.0
    assert_in_delta 100.0, summary.self_consumed_wh, 1.0
  end

  test "aggregate_day is idempotent for daily_energy_summary" do
    plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    ]
    aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7, plugs: plugs)

    start_ts = berlin_midnight_utc("2026-04-10")
    Sample.create!(plug_id: "bkw",    ts: start_ts,         apower_w: 200, aenergy_wh: 0)
    Sample.create!(plug_id: "bkw",    ts: start_ts + 600,   apower_w: 200, aenergy_wh: 33.3)
    Sample.create!(plug_id: "fridge", ts: start_ts,         apower_w: 100, aenergy_wh: 0)
    Sample.create!(plug_id: "fridge", ts: start_ts + 600,   apower_w: 100, aenergy_wh: 16.7)

    aggregator.aggregate_day("2026-04-10")
    first = DailyEnergySummary.find("2026-04-10").attributes
    aggregator.aggregate_day("2026-04-10")

    assert_equal 1, DailyEnergySummary.count
    assert_in_delta first.fetch("self_consumed_wh"), DailyEnergySummary.find("2026-04-10").self_consumed_wh, 0.01
  end

  test "aggregate_day does not write summary when plugs are not provided" do
    # Existing behavior: callers without a plug list get the legacy aggregation only.
    aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7)
    seed_day(plug_id: "bkw", date: "2026-04-10", start_energy: 1000.0, end_energy: 1800.0)

    aggregator.aggregate_day("2026-04-10")
    assert_equal 0, DailyEnergySummary.count
  end
```

Also extend the existing `setup` block to clear the new table:

```ruby
  setup do
    Sample.delete_all
    Sample5min.delete_all
    DailyTotal.delete_all
    DailyEnergySummary.delete_all  # <-- add this line

    @tz         = TZInfo::Timezone.get("Europe/Berlin")
    @aggregator = Aggregator.new(timezone: @tz, raw_retention_days: 7)
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/test_aggregator.rb`
Expected: the three new tests fail; existing ones still pass.

- [ ] **Step 3: Modify `Aggregator`**

Edit `lib/aggregator.rb`:

Change the constructor to accept plugs:

```ruby
  def initialize(timezone:, raw_retention_days: DEFAULT_RAW_RETENTION_DAYS, plugs: nil)
    @tz = timezone
    @raw_retention_days = raw_retention_days
    @plugs = plugs
  end
```

Add the require at the top of the file (alongside the existing requires):

```ruby
require "daily_energy_summary_builder"
```

In `aggregate_day`, after the two existing `ActiveRecord::Base.connection.execute` calls and **inside** the transaction, append:

```ruby
      if @plugs
        DailyEnergySummary.where(date: date_s).delete_all
        summary = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(date_s)
        DailyEnergySummary.create!(
          date: date_s,
          produced_wh: summary.fetch(:produced_wh),
          consumed_wh: summary.fetch(:consumed_wh),
          self_consumed_wh: summary.fetch(:self_consumed_wh)
        )
      end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/test_aggregator.rb`
Expected: all tests pass.

- [ ] **Step 5: Wire the plug list into the production aggregator caller**

Find where `Aggregator.new(...)` is constructed in production. Run:

```bash
grep -rn "Aggregator.new" app lib bin script config 2>/dev/null
```

For each non-test call site, pass `plugs: <config>.plugs`. The most likely location is a rake task in `lib/tasks/`. Edit that file to thread the config's plug list through.

If multiple call sites exist, update each to pass `plugs:`. Re-run `bin/rails test` after the edits.

- [ ] **Step 6: Commit**

```bash
git add lib/aggregator.rb test/test_aggregator.rb lib/tasks
git commit -m "Aggregator writes daily_energy_summary"
```

---

## Task 5: One-shot backfill data migration

For every distinct `date` in `daily_totals` that has at least one matching `samples_5min` row and no existing `daily_energy_summary`, compute and insert a summary row using the builder. Skipping silently when `samples_5min` is empty for a day matches the spec.

**Files:**
- Create: `db/migrate/20260506000001_backfill_daily_energy_summary.rb`

The migration needs the plug roles from config. We load the same config the application uses.

- [ ] **Step 1: Write the migration**

```ruby
require "config_loader"
require "daily_energy_summary_builder"
require "tzinfo"

class BackfillDailyEnergySummary < ActiveRecord::Migration[8.1]
  def up
    return if Rails.env.test?  # tests do their own seeding

    config_path = Rails.root.join("config", "ziwoas.yml")
    return unless File.exist?(config_path)

    config   = ConfigLoader.load(config_path.to_s)
    timezone = TZInfo::Timezone.get(config.timezone)
    builder  = DailyEnergySummaryBuilder.new(plugs: config.plugs, timezone: timezone)

    dates = DailyTotal.distinct.pluck(:date).sort
    dates.each do |date_s|
      next if connection.select_value(
        connection.send(:sanitize_sql_for_conditions, [ "SELECT 1 FROM daily_energy_summary WHERE date = ?", date_s ])
      )

      next unless Sample5min.where(
        bucket_ts: timezone.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i...
                   timezone.local_to_utc(Time.parse("#{date_s} 00:00:00")).to_i + 86_400
      ).exists?

      result = builder.build(date_s)
      DailyEnergySummary.create!(
        date: date_s,
        produced_wh: result.fetch(:produced_wh),
        consumed_wh: result.fetch(:consumed_wh),
        self_consumed_wh: result.fetch(:self_consumed_wh)
      )
    end
  end

  def down
    DailyEnergySummary.delete_all
  end
end
```

- [ ] **Step 2: Apply the migration**

Run: `bin/rails db:migrate && RAILS_ENV=test bin/rails db:migrate`
Expected: migration runs cleanly. In dev (with real data) `daily_energy_summary` now contains rows.

- [ ] **Step 3: Sanity-check (dev only, optional)**

Run: `bin/rails runner 'puts DailyEnergySummary.count; pp DailyEnergySummary.first(3).map(&:attributes)'`
Expected: count > 0 if `daily_totals` had any rows; rows look plausible.

- [ ] **Step 4: Commit**

```bash
git add db/migrate/20260506000001_backfill_daily_energy_summary.rb db/schema.rb
git commit -m "Backfill daily_energy_summary from samples_5min"
```

---

## Task 6: Extend `EnergySummary` with `self_consumed_wh` + ratios

For "today" the dashboard polls `EnergySummary#compute_today`, which currently sums energy deltas from raw `samples`. Add `self_consumed_wh` by ad-hoc 5-min bucketing today's raw samples, summing producer / consumer power across plugs per bucket, and applying the same min-fold + integration as the builder. Expose `autarky_ratio` and `self_consumption_ratio`.

**Files:**
- Modify: `app/models/energy_summary.rb`
- Modify: `test/models/energy_summary_test.rb`

- [ ] **Step 1: Write the failing tests**

Add these tests at the bottom of `test/models/energy_summary_test.rb` before the final `end`:

```ruby
  test "compute_today returns self_consumed_wh from simultaneous overlap" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    # 1h of producer 200W and consumer 100W simultaneously
    (0..3600).step(60) do |dt|
      Sample.create!(plug_id: "bkw",    ts: midnight + dt, apower_w: 200.0, aenergy_wh: 200.0 * dt / 3600.0)
      Sample.create!(plug_id: "fridge", ts: midnight + dt, apower_w: 100.0, aenergy_wh: 100.0 * dt / 3600.0)
    end

    summary = EnergySummary.new(config: @config).compute_today

    assert_in_delta 200.0, summary.produced_wh,      2.0
    assert_in_delta 100.0, summary.consumed_wh,      2.0
    assert_in_delta 100.0, summary.self_consumed_wh, 2.0
    assert_in_delta 1.0,   summary.autarky_ratio,           0.05
    assert_in_delta 0.5,   summary.self_consumption_ratio,  0.05
  end

  test "compute_today ratios are zero when denominator is zero" do
    summary = EnergySummary.new(config: @config).compute_today
    assert_equal 0.0, summary.autarky_ratio
    assert_equal 0.0, summary.self_consumption_ratio
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/energy_summary_test.rb`
Expected: the two new tests fail with `NoMethodError: undefined method 'self_consumed_wh'`.

- [ ] **Step 3: Modify `EnergySummary`**

Replace the contents of `app/models/energy_summary.rb` with:

```ruby
class EnergySummary
  # Plausible per-sample power ceiling used to cap energy deltas. 20 kW is
  # above any realistic single-circuit load, while counter glitches can imply
  # megawatts for a few seconds.
  MAX_PLAUSIBLE_W = 20_000
  BUCKET_SECONDS = 300

  attr_reader :produced_wh, :consumed_wh, :self_consumed_wh, :savings_eur, :date

  def initialize(config:)
    @config     = config
    @tz         = TZInfo::Timezone.get(config.timezone)
    @calculator = SavingsCalculator.new(price_eur_per_kwh: config.electricity_price_eur_per_kwh)
  end

  def compute_today
    start_ts, end_ts, today = today_bounds_utc
    @produced_wh      = energy_delta_wh(producer_ids, start_ts, end_ts)
    @consumed_wh      = energy_delta_wh(consumer_ids, start_ts, end_ts)
    @self_consumed_wh = compute_self_consumed_wh(start_ts, end_ts)
    @savings_eur      = @calculator.savings_eur(@produced_wh)
    @date             = today.to_s
    self
  end

  def autarky_ratio
    return 0.0 if @consumed_wh.nil? || @consumed_wh.zero?
    @self_consumed_wh / @consumed_wh
  end

  def self_consumption_ratio
    return 0.0 if @produced_wh.nil? || @produced_wh.zero?
    @self_consumed_wh / @produced_wh
  end

  private

  def today_bounds_utc
    now_utc     = Time.now.utc
    local_today = @tz.utc_to_local(now_utc).to_date
    midnight    = Time.new(local_today.year, local_today.month, local_today.day, 0, 0, 0)
    start_utc   = @tz.local_to_utc(midnight).to_i
    [ start_utc, start_utc + 86_400, local_today ]
  end

  def producer_ids
    @config.plugs.select { |p| p.role == :producer }.map(&:id)
  end

  def consumer_ids
    @config.plugs.select { |p| p.role == :consumer }.map(&:id)
  end

  def energy_delta_wh(plug_ids, start_ts, end_ts)
    return 0.0 if plug_ids.empty?

    sql = <<~SQL
      WITH window_samples AS (
        SELECT plug_id, ts, aenergy_wh,
               LAG(ts)         OVER (PARTITION BY plug_id ORDER BY ts) AS prev_ts,
               LAG(aenergy_wh) OVER (PARTITION BY plug_id ORDER BY ts) AS prev_wh
          FROM samples
         WHERE plug_id IN (?) AND ts >= ? AND ts < ?
      ),
      deltas AS (
        SELECT plug_id,
               CASE
                 WHEN prev_wh IS NULL      THEN 0
                 WHEN aenergy_wh < prev_wh THEN 0
                 WHEN aenergy_wh - prev_wh
                      > #{MAX_PLAUSIBLE_W}.0 * (ts - prev_ts) / 3600.0 THEN 0
                 ELSE aenergy_wh - prev_wh
               END AS delta_wh
          FROM window_samples
      )
      SELECT plug_id, SUM(delta_wh) AS delta
        FROM deltas
       GROUP BY plug_id
    SQL

    rows = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([ sql, plug_ids, start_ts, end_ts ])
    )
    rows.sum { |row| row["delta"] || 0 }.to_f
  end

  def compute_self_consumed_wh(start_ts, end_ts)
    plug_ids = @config.plugs.map(&:id)
    return 0.0 if plug_ids.empty?

    role_by_id = @config.plugs.each_with_object({}) { |p, h| h[p.id] = p.role }

    rows = ActiveRecord::Base.connection.exec_query(
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
    )

    bucket_h = BUCKET_SECONDS / 3600.0
    by_bucket = rows.group_by { |r| r["bucket_ts"] }
    total = 0.0
    by_bucket.each_value do |bucket_rows|
      prod_w = 0.0
      cons_w = 0.0
      bucket_rows.each do |row|
        case role_by_id[row["plug_id"]]
        when :producer then prod_w += row["avg_w"].to_f
        when :consumer then cons_w += row["avg_w"].to_f
        end
      end
      total += [ prod_w, cons_w ].min * bucket_h
    end
    total
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/energy_summary_test.rb`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/models/energy_summary.rb test/models/energy_summary_test.rb
git commit -m "EnergySummary computes self-consumption and ratios"
```

---

## Task 7: Expose new fields via `/api/today/summary`

**Files:**
- Modify: `app/views/api/today_summary.json.jbuilder`
- Modify: `test/controllers/api_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Add this test to `test/controllers/api_controller_test.rb` before the final `end`:

```ruby
  test "GET /api/today/summary includes self-consumption fields" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    (0..3600).step(60) do |dt|
      Sample.create!(plug_id: "bkw",    ts: midnight + dt, apower_w: 200.0, aenergy_wh: 200.0 * dt / 3600.0)
      Sample.create!(plug_id: "fridge", ts: midnight + dt, apower_w: 100.0, aenergy_wh: 100.0 * dt / 3600.0)
    end

    get "/api/today/summary", as: :json
    assert_response :ok

    data = response.parsed_body
    assert data.key?("self_consumed_wh_today")
    assert data.key?("autarky_ratio")
    assert data.key?("self_consumption_ratio")
    assert_in_delta 100.0, data["self_consumed_wh_today"], 2.0
    assert_in_delta 1.0,   data["autarky_ratio"],          0.05
    assert_in_delta 0.5,   data["self_consumption_ratio"], 0.05
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/api_controller_test.rb`
Expected: the new test fails on `data.key?("self_consumed_wh_today")`.

- [ ] **Step 3: Update the jbuilder template**

Replace the contents of `app/views/api/today_summary.json.jbuilder` with:

```ruby
json.date                   @summary.date
json.produced_wh_today      @summary.produced_wh
json.consumed_wh_today      @summary.consumed_wh
json.self_consumed_wh_today @summary.self_consumed_wh
json.autarky_ratio          @summary.autarky_ratio
json.self_consumption_ratio @summary.self_consumption_ratio
json.savings_eur_today      @summary.savings_eur
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/controllers/api_controller_test.rb`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/views/api/today_summary.json.jbuilder test/controllers/api_controller_test.rb
git commit -m "Expose self-consumption ratios on /api/today/summary"
```

---

## Task 8: Dashboard view — two new "heute" tiles

**Files:**
- Modify: `app/views/dashboard/index.html.erb`
- Modify: `test/controllers/dashboard_controller_test.rb`

- [ ] **Step 1: Write the failing test**

Open `test/controllers/dashboard_controller_test.rb` and read the existing tests. Add this test before the final `end`:

```ruby
  test "dashboard renders Autarkie and Eigenverbrauch tiles" do
    get "/"
    assert_response :ok
    labels = css_select(".tiles .tile .tile-label").map { |n| n.text.squish }
    assert_includes labels, "Autarkie heute"
    assert_includes labels, "Eigenverbrauch heute"
    assert_select "[data-dashboard-target='tileAutarky']", 1
    assert_select "[data-dashboard-target='tileSelfConsumption']", 1
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/controllers/dashboard_controller_test.rb`
Expected: FAIL — the targets do not exist.

- [ ] **Step 3: Edit the view**

In `app/views/dashboard/index.html.erb`, find the closing `</div>` of the `<div class="tiles">` block (after the existing six tiles, around line 33-34) and insert two new tiles **before** the `</div>` that closes the tiles container:

```erb
    <div class="tile">
      <div class="tile-label">Autarkie heute</div>
      <div class="tile-value" data-dashboard-target="tileAutarky">—</div>
    </div>
    <div class="tile">
      <div class="tile-label">Eigenverbrauch heute</div>
      <div class="tile-value" data-dashboard-target="tileSelfConsumption">—</div>
    </div>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/controllers/dashboard_controller_test.rb`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/views/dashboard/index.html.erb test/controllers/dashboard_controller_test.rb
git commit -m "Add Autarkie and Eigenverbrauch dashboard tiles"
```

---

## Task 9: Wire dashboard JS controller to populate the new tiles

**Files:**
- Modify: `app/javascript/controllers/dashboard_controller.js`

This is JS-only, no automated test. Verify in the browser at the end.

- [ ] **Step 1: Add the new targets to the static targets list**

In `app/javascript/controllers/dashboard_controller.js`, edit the `static targets = [...]` block and append `"tileAutarky"`, `"tileSelfConsumption"` to the line that contains `"tileProduced", "tileConsumed", "tileSavings", "tileNettoday"`:

```js
    "tileProduced", "tileConsumed", "tileSavings", "tileNettoday",
    "tileAutarky", "tileSelfConsumption",
```

- [ ] **Step 2: Render the new values in `fetchSummary()`**

In `fetchSummary()`, **after** the existing `if (this.hasTileNettodayTarget) { ... }` block and **before** the `} catch (e) {`, add:

```js
      const fmtPct = (ratio) => fmt(ratio * 100, 1) + " %"
      if (this.hasTileAutarkyTarget)
        this.tileAutarkyTarget.textContent = fmtPct(data.autarky_ratio || 0)
      if (this.hasTileSelfConsumptionTarget)
        this.tileSelfConsumptionTarget.textContent = fmtPct(data.self_consumption_ratio || 0)
```

- [ ] **Step 3: Run all tests**

Run: `bin/rails test`
Expected: all green (this step is JS-only but we want to make sure nothing else regressed).

- [ ] **Step 4: Manually verify in the browser**

Run: `bin/dev` (in another terminal).
Open `http://localhost:3000`. After the periodic 30-second `fetchSummary` refresh (or immediately on load), the two new tiles should display percentage values like `42,5 %`. Outside daylight hours both will likely show `0,0 %` — that's expected per design.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/dashboard_controller.js
git commit -m "Render Autarkie and Eigenverbrauch tiles on dashboard"
```

---

## Task 10: `EnergyReport` — read from `daily_energy_summary` and add ratios

This is the heaviest change. We replace per-plug daily folding with a direct read from `daily_energy_summary`. Per-plug data (rankings, per-consumer daily series, detail chart) continues to use `daily_totals` and `samples_5min`.

**Files:**
- Modify: `app/models/energy_report.rb`
- Modify: `test/models/energy_report_test.rb`

- [ ] **Step 1: Update existing tests for the new data source**

The existing tests in `test/models/energy_report_test.rb` use a `seed_daily(date, pv:, desk:, washer:)` helper that only writes per-plug `daily_totals`. After this task, the **summary tiles** (Ertrag, Verbrauch, Bilanz, Ø-Werte) come from `daily_energy_summary`. The existing tests must be updated to also seed `daily_energy_summary` with consistent values.

Replace the `seed_daily` helper at the bottom of the file with:

```ruby
  def seed_daily(date, pv:, desk:, washer:)
    DailyTotal.create!(plug_id: "pv",     date: date, energy_wh: pv)
    DailyTotal.create!(plug_id: "desk",   date: date, energy_wh: desk)
    DailyTotal.create!(plug_id: "washer", date: date, energy_wh: washer)
    DailyEnergySummary.create!(
      date:             date,
      produced_wh:      pv,
      consumed_wh:      desk + washer,
      self_consumed_wh: 0.0
    )
  end
```

Add `DailyEnergySummary.delete_all` to the `setup` block:

```ruby
  setup do
    DailyTotal.delete_all
    Sample5min.delete_all
    DailyEnergySummary.delete_all  # <-- add this line

    @plugs = [
      ConfigLoader::PlugCfg.new(id: "pv", name: "Balkonkraftwerk", role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "desk", name: "Schreibtisch", role: :consumer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "washer", name: "Waschmaschine", role: :consumer, driver: :shelly, ain: nil)
    ]
  end
```

Also update the existing `"empty data returns empty state without raising"` test — its hash literal needs the two new ratio keys plus `self_consumed_kwh`:

```ruby
    assert_equal(
      {
        produced_kwh:           0.0,
        consumed_kwh:           0.0,
        self_consumed_kwh:      0.0,
        savings_eur:            0.0,
        balance_kwh:            0.0,
        avg_produced_kwh:       0.0,
        avg_consumed_kwh:       0.0,
        autarky_ratio:          0.0,
        self_consumption_ratio: 0.0
      },
      report.summary
    )
```

- [ ] **Step 2: Add new failing tests**

Add these tests in `test/models/energy_report_test.rb` before the final `end`:

```ruby
  test "summary includes self-consumption and ratios from daily_energy_summary" do
    DailyTotal.create!(plug_id: "pv",     date: "2026-04-10", energy_wh: 2000)
    DailyTotal.create!(plug_id: "desk",   date: "2026-04-10", energy_wh: 700)
    DailyTotal.create!(plug_id: "washer", date: "2026-04-10", energy_wh: 300)
    DailyEnergySummary.create!(
      date: "2026-04-10",
      produced_wh: 2000.0,
      consumed_wh: 1000.0,
      self_consumed_wh: 600.0
    )

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_in_delta 2.0, report.summary.fetch(:produced_kwh)
    assert_in_delta 1.0, report.summary.fetch(:consumed_kwh)
    assert_in_delta 0.6, report.summary.fetch(:self_consumed_kwh)
    assert_in_delta 0.6, report.summary.fetch(:autarky_ratio),           0.001  # 600/1000
    assert_in_delta 0.3, report.summary.fetch(:self_consumption_ratio), 0.001  # 600/2000
  end

  test "ratios are zero when denominators are zero" do
    DailyEnergySummary.create!(
      date: "2026-04-10",
      produced_wh: 0.0,
      consumed_wh: 0.0,
      self_consumed_wh: 0.0
    )
    DailyTotal.create!(plug_id: "pv", date: "2026-04-10", energy_wh: 0)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_equal 0.0, report.summary.fetch(:autarky_ratio)
    assert_equal 0.0, report.summary.fetch(:self_consumption_ratio)
  end

  test "chart payload includes per-day ratios with nulls for gaps" do
    DailyTotal.create!(plug_id: "pv", date: "2026-04-10", energy_wh: 2000)
    DailyTotal.create!(plug_id: "pv", date: "2026-04-11", energy_wh: 2000)
    DailyEnergySummary.create!(date: "2026-04-10", produced_wh: 2000.0, consumed_wh: 1000.0, self_consumed_wh: 500.0)
    # 2026-04-11 has no daily_energy_summary row -> gap

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-11" },
      plugs: @plugs
    ).build

    ratios = report.chart_payload.fetch(:daily).fetch(:ratios)
    assert_equal 2, ratios.length
    assert_equal "2026-04-10", ratios.first.fetch(:date)
    assert_in_delta 50.0, ratios.first.fetch(:autarky_pct),           0.001
    assert_in_delta 25.0, ratios.first.fetch(:self_consumption_pct), 0.001
    assert_nil ratios.last.fetch(:autarky_pct)
    assert_nil ratios.last.fetch(:self_consumption_pct)
  end

  test "summary excludes days without daily_energy_summary from totals" do
    DailyTotal.create!(plug_id: "pv", date: "2026-04-10", energy_wh: 2000)
    DailyTotal.create!(plug_id: "pv", date: "2026-04-11", energy_wh: 2000)
    DailyEnergySummary.create!(date: "2026-04-10", produced_wh: 2000.0, consumed_wh: 1000.0, self_consumed_wh: 500.0)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-11" },
      plugs: @plugs
    ).build

    # consumed/produced come only from the covered day
    assert_in_delta 2.0, report.summary.fetch(:produced_kwh)
    assert_in_delta 1.0, report.summary.fetch(:consumed_kwh)
    assert_in_delta 0.5, report.summary.fetch(:self_consumed_kwh)
  end
```

- [ ] **Step 3: Run tests to verify the new ones fail and the existing ones still pass**

Run: `bin/rails test test/models/energy_report_test.rb`
Expected: existing tests still pass (they now seed `DailyEnergySummary` too); new tests fail because `:self_consumed_kwh`, `:autarky_ratio`, `:self_consumption_ratio`, `:ratios` are not yet emitted.

- [ ] **Step 4: Modify `EnergyReport`**

Edit `app/models/energy_report.rb`:

**a. Replace `build_daily_points` to read from `daily_energy_summary`:**

Find the existing private method `build_daily_points(rows, start_date, end_date)` (around line 144-160). Change `#build` to no longer pass `rows` to it; instead it loads summaries.

Edit the `build` method (around line 41-69) to load summaries:

```ruby
  def build
    latest = latest_aggregate_date
    return empty_report(Date.current, Date.current) if latest.nil?

    range = resolve_range(latest)
    rows = daily_rows(range.fetch(:start_date), range.fetch(:end_date))
    summaries = daily_summaries(range.fetch(:start_date), range.fetch(:end_date))
    daily_points = build_daily_points(summaries, range.fetch(:start_date), range.fetch(:end_date))
    summary = summarize(daily_points)
    selected_date = resolve_selected_date(range.fetch(:start_date), range.fetch(:end_date))
    detail_range = resolve_detail_range(range.fetch(:start_date), range.fetch(:end_date))

    Report.new(
      start_date: range.fetch(:start_date),
      end_date: range.fetch(:end_date),
      selected_date: selected_date,
      preset: range.fetch(:preset),
      summary: summary,
      daily_points: daily_points,
      producer_ranking: ranking(rows, :producer),
      consumer_ranking: ranking(rows, :consumer),
      detail_start_date: detail_range.fetch(:start_date),
      detail_end_date: detail_range.fetch(:end_date),
      chart_payload: {
        daily: daily_chart_payload(daily_points),
        detail: detail_chart_payload(rows, detail_range.fetch(:start_date), detail_range.fetch(:end_date))
      },
      messages: @messages
    )
  end
```

**b. Add `daily_summaries` private method** (insert after `daily_rows`):

```ruby
  def daily_summaries(start_date, end_date)
    DailyEnergySummary.where(date: start_date.to_s..end_date.to_s).index_by(&:date)
  end
```

**c. Replace `build_daily_points` (rewrite the whole method):**

```ruby
  def build_daily_points(summaries, start_date, end_date)
    (start_date..end_date).map do |date|
      date_s = date.to_s
      summary = summaries[date_s]
      if summary
        {
          date: date_s,
          produced_kwh:      kwh(summary.produced_wh),
          consumed_kwh:      kwh(summary.consumed_wh),
          self_consumed_kwh: kwh(summary.self_consumed_wh),
          balance_kwh:       kwh(summary.produced_wh - summary.consumed_wh),
          covered:           true
        }
      else
        {
          date: date_s,
          produced_kwh:      0.0,
          consumed_kwh:      0.0,
          self_consumed_kwh: 0.0,
          balance_kwh:       0.0,
          covered:           false
        }
      end
    end
  end
```

**d. Replace `summarize` to compute ratios and self-consumption:**

```ruby
  def summarize(daily_points)
    covered_points = daily_points.select { |p| p.fetch(:covered) }
    produced       = covered_points.sum { |p| p.fetch(:produced_kwh) }
    consumed       = covered_points.sum { |p| p.fetch(:consumed_kwh) }
    self_consumed  = covered_points.sum { |p| p.fetch(:self_consumed_kwh) }
    days = covered_points.length

    {
      produced_kwh:           produced.round(3),
      consumed_kwh:           consumed.round(3),
      self_consumed_kwh:      self_consumed.round(3),
      savings_eur:            @savings_calculator.savings_eur(produced * 1000.0).round(2),
      balance_kwh:            (produced - consumed).round(3),
      avg_produced_kwh:       average_kwh(produced, days),
      avg_consumed_kwh:       average_kwh(consumed, days),
      autarky_ratio:          ratio(self_consumed, consumed),
      self_consumption_ratio: ratio(self_consumed, produced)
    }
  end

  def ratio(numerator, denominator)
    return 0.0 if denominator.nil? || denominator.zero?
    (numerator.to_f / denominator).round(4)
  end
```

**e. Update `empty_summary` to include the new keys:**

```ruby
  def empty_summary
    {
      produced_kwh:           0.0,
      consumed_kwh:           0.0,
      self_consumed_kwh:      0.0,
      savings_eur:            0.0,
      balance_kwh:            0.0,
      avg_produced_kwh:       0.0,
      avg_consumed_kwh:       0.0,
      autarky_ratio:          0.0,
      self_consumption_ratio: 0.0
    }
  end
```

**f. Update `daily_chart_payload` to add the `ratios` array:**

Replace the existing `daily_chart_payload` method:

```ruby
  def daily_chart_payload(daily_points)
    {
      labels: daily_points.map { |point| Date.iso8601(point.fetch(:date)).strftime("%d.%m.") },
      produced_kwh: daily_points.map { |point| point.fetch(:produced_kwh) },
      consumed_kwh: daily_points.map { |point| point.fetch(:consumed_kwh) },
      balance_kwh: daily_points.map { |point| point.fetch(:balance_kwh) },
      consumer_series: consumer_daily_series(daily_points.map { |point| point.fetch(:date) }),
      ratios: daily_points.map { |point| ratio_point(point) }
    }
  end

  def ratio_point(point)
    if point.fetch(:covered)
      {
        date: point.fetch(:date),
        autarky_pct:           ratio_pct(point.fetch(:self_consumed_kwh), point.fetch(:consumed_kwh)),
        self_consumption_pct:  ratio_pct(point.fetch(:self_consumed_kwh), point.fetch(:produced_kwh))
      }
    else
      { date: point.fetch(:date), autarky_pct: nil, self_consumption_pct: nil }
    end
  end

  def ratio_pct(numerator, denominator)
    return 0.0 if denominator.nil? || denominator.zero?
    ((numerator.to_f / denominator) * 100).round(1)
  end
```

**g. Update `empty_report` chart payload to include the new keys:**

In `empty_report`, change the `daily:` payload entry:

```ruby
        daily: { labels: [], produced_kwh: [], consumed_kwh: [], balance_kwh: [], consumer_series: [], ratios: [] },
```

- [ ] **Step 5: Run tests to verify all pass**

Run: `bin/rails test test/models/energy_report_test.rb`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/models/energy_report.rb test/models/energy_report_test.rb
git commit -m "EnergyReport reads totals from daily_energy_summary; expose ratios"
```

---

## Task 11: Reports view — two new tiles + ratios chart canvas

**Files:**
- Modify: `app/views/reports/index.html.erb`
- Modify: `test/controllers/reports_controller_test.rb`

- [ ] **Step 1: Update the existing controller test for the new tile count**

Find the test `"reports page renders summary ranking and chart payload"` in `test/controllers/reports_controller_test.rb`. The current expectation is `assert_select ".tiles .tile", 6`. Update it to `8` and update the `labels` assertion:

```ruby
    assert_select ".tiles .tile", 8
    labels = css_select(".tiles .tile .tile-label").map { |node| node.text.squish }
    assert_equal [ "Ertrag", "Verbrauch", "Gespart", "Bilanz", "Autarkie", "Eigenverbrauch", "Ø Ertrag/Tag", "Ø Verbrauch/Tag" ], labels
```

- [ ] **Step 2: Add a new test for the ratios chart and section label**

Add this test before the final `end`:

```ruby
  test "reports page renders Autarkie & Eigenverbrauchsquote section" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-04-10", energy_wh: 2000)
    DailyEnergySummary.create!(date: "2026-04-10", produced_wh: 2000.0, consumed_wh: 1000.0, self_consumed_wh: 500.0)

    get "/reports"

    assert_response :success
    assert_select ".section-label", text: "Autarkie & Eigenverbrauchsquote"
    assert_select "[data-energy-report-target='ratiosCanvas']", 1
  end
```

Also extend the setup to clear the new table:

```ruby
  setup do
    DailyTotal.delete_all
    DailyEnergySummary.delete_all
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/controllers/reports_controller_test.rb`
Expected: new tests fail; the updated tile-count test fails.

- [ ] **Step 4: Edit the view**

In `app/views/reports/index.html.erb`, modify the `<section class="tiles">` block. **After** the Bilanz tile and **before** the Ø Ertrag/Tag tile, insert two new tiles:

```erb
      <div class="tile">
        <div class="tile-label">Autarkie</div>
        <div class="tile-value"><%= number_with_precision(@report.summary.fetch(:autarky_ratio) * 100, precision: 1, delimiter: ".", separator: ",") %> %</div>
      </div>
      <div class="tile">
        <div class="tile-label">Eigenverbrauch</div>
        <div class="tile-value"><%= number_with_precision(@report.summary.fetch(:self_consumption_ratio) * 100, precision: 1, delimiter: ".", separator: ",") %> %</div>
      </div>
```

Also, **after** the existing energy chart section (the `<div class="section-label">Energie — Ertrag / Verbrauch</div>` block and its sibling `<div class="chart-card">`) and **before** the Leistung section, insert:

```erb
    <div class="section-label">Autarkie & Eigenverbrauchsquote</div>
    <div class="chart-card">
      <div class="chart-frame">
        <canvas data-energy-report-target="ratiosCanvas"></canvas>
      </div>
    </div>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bin/rails test test/controllers/reports_controller_test.rb`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/views/reports/index.html.erb test/controllers/reports_controller_test.rb
git commit -m "Add Autarkie/Eigenverbrauch tiles and chart to reports page"
```

---

## Task 12: Stimulus controller — render the ratios chart

**Files:**
- Modify: `app/javascript/controllers/energy_report_controller.js`

JS-only; no Minitest coverage. Verify in the browser at the end.

- [ ] **Step 1: Add the new target**

In `app/javascript/controllers/energy_report_controller.js`, change the `static targets` declaration from:

```js
  static targets = ["payload", "dailyCanvas", "detailCanvas"]
```

to:

```js
  static targets = ["payload", "dailyCanvas", "ratiosCanvas", "detailCanvas"]
```

- [ ] **Step 2: Build the ratios chart on connect**

In `connect()`, after `this._buildDailyChart()` and before `this._buildDetailChart()`, call:

```js
    this._buildRatiosChart()
```

In `disconnect()`, add the teardown:

```js
    this.ratiosChart?.destroy()
```

In the constructor list near the top of `connect()` add:

```js
    this.ratiosChart = null
```

- [ ] **Step 3: Implement `_buildRatiosChart()`**

Add the new method before `_buildDetailChart()`:

```js
  _buildRatiosChart() {
    if (!this.hasRatiosCanvasTarget) return

    const daily = this.payload.daily || {}
    const ratios = daily.ratios || []
    const labels = ratios.map((r) => {
      const [, m, d] = r.date.split("-")
      return `${d}.${m}.`
    })
    const autarky = ratios.map((r) => (r.autarky_pct === null ? null : r.autarky_pct))
    const selfCons = ratios.map((r) => (r.self_consumption_pct === null ? null : r.self_consumption_pct))

    this.ratiosChart = this._replaceChart(this.ratiosCanvasTarget, {
      type: "line",
      data: {
        labels,
        datasets: [
          {
            label: "Autarkie",
            data: autarky,
            borderColor: "#10b981",
            backgroundColor: "#10b981",
            spanGaps: false,
            fill: false,
            tension: 0.2,
            pointRadius: 3,
          },
          {
            label: "Eigenverbrauch",
            data: selfCons,
            borderColor: "#f59f00",
            backgroundColor: "#f59f00",
            spanGaps: false,
            fill: false,
            tension: 0.2,
            pointRadius: 3,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          y: { min: 0, max: 100, title: { display: true, text: "%" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }
```

- [ ] **Step 4: Run all tests**

Run: `bin/rails test`
Expected: all green.

- [ ] **Step 5: Manually verify in the browser**

Run: `bin/dev`. Navigate to `http://localhost:3000/reports`. With seeded `daily_energy_summary` data, the new section "Autarkie & Eigenverbrauchsquote" should appear with a two-line chart between 0–100 %. Days without coverage should show as gaps (no point connection). Switch presets (7 / 30 days) and a custom range to verify behaviour.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/controllers/energy_report_controller.js
git commit -m "Render Autarkie/Eigenverbrauch ratios chart"
```

---

## Task 13: Final integration test

**Files:**
- (no new files; runs the full suite)

- [ ] **Step 1: Run the entire test suite**

Run: `bin/rails test`
Expected: all green.

- [ ] **Step 2: Run lint / static checks if available**

Run: `bin/rubocop` (if `.rubocop.yml` is wired) and `bin/rake reek` (if reek is configured). If either is not configured, skip.

- [ ] **Step 3: Smoke test in the browser**

Run: `bin/dev`. With dev data:
- Dashboard at `/`: new tiles "Autarkie heute" / "Eigenverbrauch heute" populate via 30-second polling and show plausible percentage values.
- Reports at `/reports`: new "Autarkie" / "Eigenverbrauch" tiles show range-aggregated percentages; new chart appears between the energy chart and the power detail chart.
- Toggle 7-day / 30-day presets and a custom range. Verify percentages and the chart update.

- [ ] **Step 4: Commit any final fixes**

If any small UI tweak is required (CSS spacing, etc.), make it and commit:

```bash
git add -p
git commit -m "Polish ratios chart styling"
```

---

## Out-of-Scope Reminders

These belong to **future** work and must NOT be added in this plan:

- Sample-precise step-function integration over raw samples — current 5-min resolution is sufficient (see spec).
- Intraday chart of ratios on the dashboard.
- Per-plug autarky breakdown.
- Grid feed-in metering.
- Threshold/blanking for small denominators (the spec explicitly chose option C: always show, no blanking).
