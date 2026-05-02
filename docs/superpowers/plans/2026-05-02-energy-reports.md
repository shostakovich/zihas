# Energy Reports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Rails-first `/reports` page for detailed energy production and consumption retrospectives across last 7 days, last 30 days, and custom date ranges.

**Architecture:** Rails owns report parsing, aggregation, formatting inputs, and initial HTML rendering. A focused `EnergyReport` query object reads `daily_totals` and `samples_5min`, while a Stimulus controller only initializes Chart.js from embedded JSON. The first version uses completed daily aggregates for multi-day reports and 5-minute aggregate data for selected-day drilldown.

**Tech Stack:** Rails 8, ActiveRecord, Minitest, ERB, Stimulus, Chart.js, existing `public/app.css`.

---

## File Structure

- Create `app/models/energy_report.rb`: query object for date range parsing, daily totals, per-plug ranking, chart payloads, and selected-day drilldown.
- Ensure `app/models/sample_5min.rb` exists: ActiveRecord model for `samples_5min`.
- Create `app/controllers/reports_controller.rb`: Rails-first page controller.
- Modify `config/routes.rb`: add `/reports`.
- Modify `app/views/layouts/application.html.erb`: add global navigation around the yielded page.
- Create `app/views/reports/index.html.erb`: server-rendered report page with embedded JSON for charts.
- Create `app/javascript/controllers/energy_report_controller.js`: Chart.js initialization and teardown.
- Modify `app/javascript/controllers/index.js`: ensure the new Stimulus controller is registered if this app does not rely on auto-registration for local controllers.
- Modify `public/app.css`: responsive navigation, report layout, controls, summary metrics, ranking, empty states.
- Create `test/models/energy_report_test.rb`: query object coverage.
- Create `test/controllers/reports_controller_test.rb`: route/controller/rendering coverage.

## Implementation Decisions

- Preset ranges end at the latest fully aggregated day in `daily_totals`, not the partially open current day. This avoids mixing daily finished data with partial raw/current data in the first version.
- If there are no daily aggregates yet, the report renders an empty state using `Date.current` as the display anchor.
- Custom ranges are clamped so their end date does not exceed the latest fully aggregated day.
- If `start_date` is after `end_date`, fall back to the default last-7-days range and expose a page message.
- The first version omits self-consumption/coverage metrics because current data only has production and measured consumer plug totals, not enough grid import/export history for a reliable whole-home metric.

---

### Task 1: EnergyReport Query Object

**Files:**
- Create: `app/models/energy_report.rb`
- Ensure/create: `app/models/sample_5min.rb`
- Test: `test/models/energy_report_test.rb`

- [ ] **Step 1: Write the failing model tests**

Create `test/models/energy_report_test.rb`:

```ruby
require "test_helper"

class EnergyReportTest < ActiveSupport::TestCase
  setup do
    DailyTotal.delete_all
    Sample5min.delete_all

    @plugs = [
      ConfigLoader::PlugCfg.new(id: "pv", name: "Balkonkraftwerk", role: :producer, driver: :shelly, host: "pv.local", ain: nil),
      ConfigLoader::PlugCfg.new(id: "desk", name: "Schreibtisch", role: :consumer, driver: :shelly, host: "desk.local", ain: nil),
      ConfigLoader::PlugCfg.new(id: "washer", name: "Waschmaschine", role: :consumer, driver: :shelly, host: "washer.local", ain: nil),
    ]
  end

  test "defaults to the last seven fully aggregated days" do
    seed_daily("2026-04-01", pv: 1000, desk: 100, washer: 200)
    seed_daily("2026-04-02", pv: 1100, desk: 150, washer: 250)
    seed_daily("2026-04-03", pv: 1200, desk: 160, washer: 260)
    seed_daily("2026-04-04", pv: 1300, desk: 170, washer: 270)
    seed_daily("2026-04-05", pv: 1400, desk: 180, washer: 280)
    seed_daily("2026-04-06", pv: 1500, desk: 190, washer: 290)
    seed_daily("2026-04-07", pv: 1600, desk: 200, washer: 300)
    seed_daily("2026-04-08", pv: 1700, desk: 210, washer: 310)

    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert_equal Date.new(2026, 4, 2), report.start_date
    assert_equal Date.new(2026, 4, 8), report.end_date
    assert_equal "last_7", report.preset
    assert_equal 7, report.daily_points.length
    assert_in_delta 9.8, report.summary.fetch(:produced_kwh)
    assert_in_delta 3.22, report.summary.fetch(:consumed_kwh)
    assert_in_delta 6.58, report.summary.fetch(:balance_kwh)
  end

  test "last thirty preset uses thirty fully aggregated days ending at latest day" do
    35.times do |i|
      date = Date.new(2026, 3, 1) + i
      seed_daily(date.to_s, pv: 1000, desk: 100, washer: 200)
    end

    report = EnergyReport.new(params: { preset: "last_30" }, plugs: @plugs).build

    assert_equal Date.new(2026, 3, 6), report.start_date
    assert_equal Date.new(2026, 4, 4), report.end_date
    assert_equal 30, report.daily_points.length
  end

  test "custom range is parsed and clamped to latest aggregate" do
    seed_daily("2026-04-10", pv: 1000, desk: 100, washer: 200)
    seed_daily("2026-04-11", pv: 2000, desk: 200, washer: 300)
    seed_daily("2026-04-12", pv: 3000, desk: 300, washer: 400)

    report = EnergyReport.new(
      params: { start_date: "2026-04-11", end_date: "2026-04-30" },
      plugs: @plugs
    ).build

    assert_equal Date.new(2026, 4, 11), report.start_date
    assert_equal Date.new(2026, 4, 12), report.end_date
    assert_equal "custom", report.preset
    assert_equal 2, report.daily_points.length
  end

  test "invalid reversed range falls back with a message" do
    seed_daily("2026-04-10", pv: 1000, desk: 100, washer: 200)

    report = EnergyReport.new(
      params: { start_date: "2026-04-20", end_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_equal "last_7", report.preset
    assert_equal ["Der Datumsbereich war ungueltig und wurde auf die letzten 7 Tage zurueckgesetzt."], report.messages
  end

  test "builds per plug ranking split by role" do
    seed_daily("2026-04-10", pv: 2000, desk: 700, washer: 300)
    seed_daily("2026-04-11", pv: 3000, desk: 500, washer: 1000)

    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert_equal ["Balkonkraftwerk"], report.producer_ranking.map { |row| row.fetch(:name) }
    assert_equal ["Waschmaschine", "Schreibtisch"], report.consumer_ranking.map { |row| row.fetch(:name) }
    assert_in_delta 5.0, report.producer_ranking.first.fetch(:kwh)
    assert_in_delta 1.2, report.consumer_ranking.second.fetch(:kwh)
  end

  test "builds chart payloads for daily and selected day detail" do
    seed_daily("2026-04-10", pv: 2000, desk: 700, washer: 300)
    start_ts = Time.utc(2026, 4, 10, 0, 0, 0).to_i
    Sample5min.create!(plug_id: "pv", bucket_ts: start_ts, avg_power_w: 120, energy_delta_wh: 10, sample_count: 2)
    Sample5min.create!(plug_id: "desk", bucket_ts: start_ts, avg_power_w: 30, energy_delta_wh: 3, sample_count: 2)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-10", selected_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_equal ["2026-04-10"], report.chart_payload.fetch(:daily).fetch(:labels)
    assert_equal [2.0], report.chart_payload.fetch(:daily).fetch(:produced_kwh)
    assert_equal [1.0], report.chart_payload.fetch(:daily).fetch(:consumed_kwh)
    assert_equal 2, report.chart_payload.fetch(:detail).fetch(:series).length
  end

  test "empty data returns empty state without raising" do
    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert report.empty?
    assert_equal [], report.daily_points
    assert_equal({ produced_kwh: 0.0, consumed_kwh: 0.0, balance_kwh: 0.0 }, report.summary)
    assert_equal [], report.chart_payload.fetch(:daily).fetch(:labels)
  end

  private

  def seed_daily(date, pv:, desk:, washer:)
    DailyTotal.create!(plug_id: "pv", date: date, energy_wh: pv)
    DailyTotal.create!(plug_id: "desk", date: date, energy_wh: desk)
    DailyTotal.create!(plug_id: "washer", date: date, energy_wh: washer)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
bin/rails test test/models/energy_report_test.rb
```

Expected: failure because `EnergyReport` is not defined, or because `Sample5min` is missing if that model is not tracked yet.

- [ ] **Step 3: Ensure the Sample5min model exists**

If `app/models/sample_5min.rb` is missing from the working tree, create it with:

```ruby
class Sample5min < ApplicationRecord
  self.table_name = "samples_5min"
  self.primary_key = [:plug_id, :bucket_ts]
end
```

If it already exists with that content, do not rewrite it.

- [ ] **Step 4: Implement EnergyReport**

Create `app/models/energy_report.rb`:

```ruby
require "date"
require "tzinfo"

class EnergyReport
  Report = Struct.new(
    :start_date,
    :end_date,
    :selected_date,
    :preset,
    :summary,
    :daily_points,
    :producer_ranking,
    :consumer_ranking,
    :chart_payload,
    :messages,
    keyword_init: true
  ) do
    def empty?
      daily_points.empty?
    end
  end

  DEFAULT_PRESET = "last_7"
  PRESET_DAYS = {
    "last_7" => 7,
    "last_30" => 30,
  }.freeze

  def initialize(params:, plugs:, timezone: "UTC")
    @params = params.to_h.with_indifferent_access
    @plugs = plugs
    @plug_by_id = plugs.index_by(&:id)
    @timezone = TZInfo::Timezone.get(timezone)
    @messages = []
  end

  def build
    latest = latest_aggregate_date
    return empty_report(Date.current, Date.current) if latest.nil?

    range = resolve_range(latest)
    rows = daily_rows(range.fetch(:start_date), range.fetch(:end_date))
    daily_points = build_daily_points(rows, range.fetch(:start_date), range.fetch(:end_date))
    summary = summarize(daily_points)
    selected_date = resolve_selected_date(range.fetch(:start_date), range.fetch(:end_date))

    Report.new(
      start_date: range.fetch(:start_date),
      end_date: range.fetch(:end_date),
      selected_date: selected_date,
      preset: range.fetch(:preset),
      summary: summary,
      daily_points: daily_points,
      producer_ranking: ranking(rows, :producer),
      consumer_ranking: ranking(rows, :consumer),
      chart_payload: {
        daily: daily_chart_payload(daily_points),
        detail: detail_chart_payload(selected_date),
      },
      messages: @messages
    )
  end

  private

  def latest_aggregate_date
    value = DailyTotal.maximum(:date)
    value.present? ? Date.iso8601(value) : nil
  end

  def empty_report(start_date, end_date)
    Report.new(
      start_date: start_date,
      end_date: end_date,
      selected_date: start_date,
      preset: DEFAULT_PRESET,
      summary: { produced_kwh: 0.0, consumed_kwh: 0.0, balance_kwh: 0.0 },
      daily_points: [],
      producer_ranking: [],
      consumer_ranking: [],
      chart_payload: {
        daily: { labels: [], produced_kwh: [], consumed_kwh: [], balance_kwh: [] },
        detail: { labels: [], series: [] },
      },
      messages: @messages
    )
  end

  def resolve_range(latest)
    if custom_range_requested?
      start_date = parse_date(@params[:start_date])
      end_date = parse_date(@params[:end_date])

      if start_date && end_date && start_date <= end_date
        end_date = [end_date, latest].min
        start_date = [start_date, end_date].min
        return { start_date: start_date, end_date: end_date, preset: "custom" }
      end

      @messages << "Der Datumsbereich war ungueltig und wurde auf die letzten 7 Tage zurueckgesetzt."
    end

    preset = PRESET_DAYS.key?(@params[:preset]) ? @params[:preset] : DEFAULT_PRESET
    days = PRESET_DAYS.fetch(preset)
    { start_date: latest - (days - 1), end_date: latest, preset: preset }
  end

  def custom_range_requested?
    @params[:start_date].present? || @params[:end_date].present?
  end

  def parse_date(value)
    return nil if value.blank?
    Date.iso8601(value)
  rescue ArgumentError
    nil
  end

  def resolve_selected_date(start_date, end_date)
    parsed = parse_date(@params[:selected_date])
    return parsed if parsed && parsed >= start_date && parsed <= end_date
    end_date
  end

  def daily_rows(start_date, end_date)
    DailyTotal.where(date: start_date.to_s..end_date.to_s).to_a
  end

  def build_daily_points(rows, start_date, end_date)
    rows_by_date = rows.group_by(&:date)

    (start_date..end_date).map do |date|
      date_s = date.to_s
      day_rows = rows_by_date.fetch(date_s, [])
      produced_wh = sum_role(day_rows, :producer)
      consumed_wh = sum_role(day_rows, :consumer)

      {
        date: date_s,
        produced_kwh: kwh(produced_wh),
        consumed_kwh: kwh(consumed_wh),
        balance_kwh: kwh(produced_wh - consumed_wh),
      }
    end
  end

  def summarize(daily_points)
    produced = daily_points.sum { |point| point.fetch(:produced_kwh) }
    consumed = daily_points.sum { |point| point.fetch(:consumed_kwh) }
    {
      produced_kwh: produced.round(3),
      consumed_kwh: consumed.round(3),
      balance_kwh: (produced - consumed).round(3),
    }
  end

  def ranking(rows, role)
    rows
      .select { |row| plug_role(row.plug_id) == role }
      .group_by(&:plug_id)
      .map do |plug_id, plug_rows|
        plug = @plug_by_id.fetch(plug_id)
        {
          plug_id: plug_id,
          name: plug.name,
          role: role.to_s,
          kwh: kwh(plug_rows.sum(&:energy_wh)),
        }
      end
      .sort_by { |row| -row.fetch(:kwh) }
  end

  def daily_chart_payload(daily_points)
    {
      labels: daily_points.map { |point| point.fetch(:date) },
      produced_kwh: daily_points.map { |point| point.fetch(:produced_kwh) },
      consumed_kwh: daily_points.map { |point| point.fetch(:consumed_kwh) },
      balance_kwh: daily_points.map { |point| point.fetch(:balance_kwh) },
    }
  end

  def detail_chart_payload(selected_date)
    local_midnight = Time.new(selected_date.year, selected_date.month, selected_date.day, 0, 0, 0)
    start_ts = @timezone.local_to_utc(local_midnight).to_i
    end_ts = start_ts + 86_400
    rows = Sample5min.where(bucket_ts: start_ts...end_ts).order(:bucket_ts).to_a
    timestamps = rows.map(&:bucket_ts).uniq.sort

    series = @plugs.map do |plug|
      plug_rows = rows.select { |row| row.plug_id == plug.id }
      points_by_ts = plug_rows.index_by(&:bucket_ts)
      {
        plug_id: plug.id,
        name: plug.name,
        role: plug.role.to_s,
        data: timestamps.map do |ts|
          row = points_by_ts[ts]
          row ? watt_value(row.avg_power_w, plug.role) : nil
        end,
      }
    end.select { |series_row| series_row.fetch(:data).any?(&:present?) }

    {
      labels: timestamps.map { |ts| Time.at(ts).strftime("%H:%M") },
      series: series,
    }
  end

  def sum_role(rows, role)
    rows.select { |row| plug_role(row.plug_id) == role }.sum(&:energy_wh)
  end

  def plug_role(plug_id)
    @plug_by_id[plug_id]&.role
  end

  def watt_value(value, role)
    role == :producer ? value.abs.round(1) : value.round(1)
  end

  def kwh(wh)
    (wh.to_f / 1000.0).round(3)
  end
end
```

- [ ] **Step 5: Run the model tests**

Run:

```bash
bin/rails test test/models/energy_report_test.rb
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 1**

Run:

```bash
git add app/models/energy_report.rb app/models/sample_5min.rb test/models/energy_report_test.rb
git commit -m "feat: add energy report query object"
```

---

### Task 2: Reports Route And Controller

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/reports_controller.rb`
- Test: `test/controllers/reports_controller_test.rb`

- [ ] **Step 1: Write the failing controller tests**

Create `test/controllers/reports_controller_test.rb`:

```ruby
require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    DailyTotal.delete_all
  end

  test "reports page renders" do
    get "/reports"

    assert_response :success
    assert_select "h1", "Berichte"
  end

  test "reports page accepts custom range params" do
    get "/reports", params: { start_date: "2026-04-01", end_date: "2026-04-07" }

    assert_response :success
    assert_select "input[name='start_date'][value='2026-04-01']"
    assert_select "input[name='end_date'][value='2026-04-07']"
  end
end
```

- [ ] **Step 2: Run the controller test to verify it fails**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: route/controller/view is missing.

- [ ] **Step 3: Add the route**

Modify `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  root "dashboard#index"

  get "/reports", to: "reports#index"

  get "/api/today", to: "api#today"
  get "/api/today/summary", to: "api#today_summary"
  get "/api/history", to: "api#history"
  get "/api/live", to: "api#live"

  get "up" => "rails/health#show", as: :rails_health_check
end
```

- [ ] **Step 4: Add the controller**

Create `app/controllers/reports_controller.rb`:

```ruby
class ReportsController < ApplicationController
  def index
    @report = EnergyReport.new(
      params: report_params,
      plugs: app_config.plugs,
      timezone: app_config.timezone
    ).build
  end

  private

  def report_params
    params.permit(:preset, :start_date, :end_date, :selected_date)
  end

  def app_config
    Rails.application.ziwoas_app.config
  end
end
```

- [ ] **Step 5: Add a temporary minimal view so the route passes**

Create `app/views/reports/index.html.erb`:

```erb
<% content_for :title, "Berichte" %>

<h1>Berichte</h1>

<form method="get" action="/reports">
  <input type="date" name="start_date" value="<%= @report.start_date %>">
  <input type="date" name="end_date" value="<%= @report.end_date %>">
  <button type="submit">Anwenden</button>
</form>
```

- [ ] **Step 6: Run the controller tests**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 7: Commit Task 2**

Run:

```bash
git add config/routes.rb app/controllers/reports_controller.rb app/views/reports/index.html.erb test/controllers/reports_controller_test.rb
git commit -m "feat: add reports page route"
```

---

### Task 3: Rails-rendered Report View

**Files:**
- Modify: `app/views/reports/index.html.erb`
- Modify: `test/controllers/reports_controller_test.rb`

- [ ] **Step 1: Extend controller tests for rendered report content**

Append these tests to `test/controllers/reports_controller_test.rb`:

```ruby
test "reports page renders summary ranking and chart payload" do
  DailyTotal.create!(plug_id: "bkw", date: "2026-04-10", energy_wh: 2000)

  get "/reports"

  assert_response :success
  assert_select ".report-summary-card", minimum: 3
  assert_select "[data-energy-report-target='dailyCanvas']", 1
  assert_select "[data-energy-report-target='detailCanvas']", 1
  assert_select "script[data-energy-report-target='payload']", 1
end

test "reports page shows empty state without data" do
  get "/reports"

  assert_response :success
  assert_select ".empty-state", text: /Noch keine Berichtsdaten/
end
```

- [ ] **Step 2: Run controller tests to verify they fail**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: assertions fail because the view is still minimal.

- [ ] **Step 3: Replace the report view**

Replace `app/views/reports/index.html.erb` with:

```erb
<% content_for :title, "Berichte" %>

<div class="reports-page" data-controller="energy-report">
  <header class="page-header">
    <div>
      <h1>Berichte</h1>
      <p class="page-subtitle">Rueckschau fuer Ertrag und Verbrauch</p>
    </div>
  </header>

  <section class="report-panel report-controls" aria-label="Zeitraum">
    <div class="preset-actions" role="group" aria-label="Schnellauswahl">
      <%= link_to "Letzte 7 Tage", reports_path(preset: "last_7"), class: ["preset-link", ("active" if @report.preset == "last_7")] %>
      <%= link_to "Letzte 30 Tage", reports_path(preset: "last_30"), class: ["preset-link", ("active" if @report.preset == "last_30")] %>
    </div>

    <%= form_with url: reports_path, method: :get, local: true, class: "date-range-form" do %>
      <label>
        <span>Von</span>
        <%= date_field_tag :start_date, @report.start_date, max: @report.end_date %>
      </label>
      <label>
        <span>Bis</span>
        <%= date_field_tag :end_date, @report.end_date, max: @report.end_date %>
      </label>
      <%= submit_tag "Anwenden" %>
    <% end %>
  </section>

  <% @report.messages.each do |message| %>
    <p class="report-message"><%= message %></p>
  <% end %>

  <% if @report.empty? %>
    <section class="empty-state">
      <h2>Noch keine Berichtsdaten</h2>
      <p>Die Rueckschau erscheint, sobald die erste Tagesaggregation vorhanden ist.</p>
    </section>
  <% else %>
    <section class="report-summary-grid" aria-label="Zusammenfassung">
      <div class="report-summary-card">
        <span>Ertrag</span>
        <strong><%= number_with_precision(@report.summary.fetch(:produced_kwh), precision: 2, delimiter: ".", separator: ",") %> kWh</strong>
      </div>
      <div class="report-summary-card">
        <span>Verbrauch</span>
        <strong><%= number_with_precision(@report.summary.fetch(:consumed_kwh), precision: 2, delimiter: ".", separator: ",") %> kWh</strong>
      </div>
      <div class="report-summary-card">
        <span>Bilanz</span>
        <strong><%= number_with_precision(@report.summary.fetch(:balance_kwh), precision: 2, delimiter: ".", separator: ",") %> kWh</strong>
      </div>
    </section>

    <section class="report-grid">
      <div class="report-panel chart-panel">
        <div class="panel-heading">
          <h2>Ertrag und Verbrauch</h2>
          <span><%= @report.start_date %> bis <%= @report.end_date %></span>
        </div>
        <canvas data-energy-report-target="dailyCanvas"></canvas>
      </div>

      <aside class="report-panel ranking-panel">
        <h2>Sensoren</h2>
        <h3>Erzeuger</h3>
        <%= render "ranking", rows: @report.producer_ranking %>
        <h3>Verbraucher</h3>
        <%= render "ranking", rows: @report.consumer_ranking %>
      </aside>
    </section>

    <section class="report-panel chart-panel">
      <div class="panel-heading">
        <h2>Detailverlauf</h2>
        <span><%= @report.selected_date %></span>
      </div>
      <canvas data-energy-report-target="detailCanvas"></canvas>
    </section>
  <% end %>

  <script type="application/json" data-energy-report-target="payload"><%= raw JSON.generate(@report.chart_payload) %></script>
</div>
```

Create `app/views/reports/_ranking.html.erb`:

```erb
<% if rows.any? %>
  <ol class="ranking-list">
    <% rows.each do |row| %>
      <li>
        <span><%= row.fetch(:name) %></span>
        <strong><%= number_with_precision(row.fetch(:kwh), precision: 2, delimiter: ".", separator: ",") %> kWh</strong>
      </li>
    <% end %>
  </ol>
<% else %>
  <p class="muted-text">Keine Daten</p>
<% end %>
```

- [ ] **Step 4: Run controller tests**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add app/views/reports/index.html.erb app/views/reports/_ranking.html.erb test/controllers/reports_controller_test.rb
git commit -m "feat: render energy reports page"
```

---

### Task 4: Chart.js Stimulus Controller

**Files:**
- Create: `app/javascript/controllers/energy_report_controller.js`
- Modify: `app/javascript/controllers/index.js` only if needed

- [ ] **Step 1: Inspect controller registration**

Run:

```bash
sed -n '1,200p' app/javascript/controllers/index.js
```

Expected: either `eagerLoadControllersFrom("controllers", application)` is present, or controllers are manually registered.

- [ ] **Step 2: Add the Stimulus controller**

Create `app/javascript/controllers/energy_report_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"
import "chart.js"

// Connects to data-controller="energy-report"
// Rails renders the report data; this controller only turns embedded JSON into charts.
export default class extends Controller {
  static targets = ["payload", "dailyCanvas", "detailCanvas"]

  connect() {
    this.dailyChart = null
    this.detailChart = null
    this.payload = this._readPayload()
    this._buildDailyChart()
    this._buildDetailChart()
  }

  disconnect() {
    this.dailyChart?.destroy()
    this.detailChart?.destroy()
  }

  _readPayload() {
    if (!this.hasPayloadTarget) return { daily: {}, detail: {} }

    try {
      return JSON.parse(this.payloadTarget.textContent)
    } catch (error) {
      console.error("energy report payload parse failed:", error)
      return { daily: {}, detail: {} }
    }
  }

  _buildDailyChart() {
    if (!this.hasDailyCanvasTarget) return

    const daily = this.payload.daily || {}
    const labels = daily.labels || []

    this.dailyChart = new Chart(this.dailyCanvasTarget, {
      type: "bar",
      data: {
        labels,
        datasets: [
          {
            label: "Ertrag",
            data: daily.produced_kwh || [],
            backgroundColor: "#f59f00",
          },
          {
            label: "Verbrauch",
            data: daily.consumed_kwh || [],
            backgroundColor: "#3b82f6",
          },
          {
            label: "Bilanz",
            data: daily.balance_kwh || [],
            type: "line",
            borderColor: "#10b981",
            backgroundColor: "#10b981",
            tension: 0.2,
            pointRadius: 2,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          y: { beginAtZero: true, title: { display: true, text: "kWh" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }

  _buildDetailChart() {
    if (!this.hasDetailCanvasTarget) return

    const detail = this.payload.detail || {}
    const labels = detail.labels || []
    const colors = ["#f59f00", "#3b82f6", "#10b981", "#8b5cf6", "#ef4444", "#06b6d4", "#ec4899"]

    const datasets = (detail.series || []).map((series, index) => {
      const color = series.role === "producer" ? "#f59f00" : colors[index % colors.length]
      return {
        label: series.name,
        data: series.data,
        borderColor: color,
        backgroundColor: color,
        tension: 0.2,
        pointRadius: 0,
      }
    })

    this.detailChart = new Chart(this.detailCanvasTarget, {
      type: "line",
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          y: { beginAtZero: true, title: { display: true, text: "Watt" } },
        },
        plugins: { legend: { position: "bottom" } },
        animation: false,
      },
    })
  }
}
```

- [ ] **Step 3: Register controller manually only if needed**

If `app/javascript/controllers/index.js` manually registers each controller, add:

```javascript
import EnergyReportController from "./energy_report_controller"
application.register("energy-report", EnergyReportController)
```

If it uses eager loading, make no change.

- [ ] **Step 4: Run JavaScript/import smoke check**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: Rails tests still pass. JavaScript import errors may only surface in browser/system checks, so this is a partial check.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add app/javascript/controllers/energy_report_controller.js app/javascript/controllers/index.js
git commit -m "feat: add energy report charts"
```

If `index.js` was not changed, omit it from `git add`.

---

### Task 5: Navigation And Responsive Styling

**Files:**
- Modify: `app/views/layouts/application.html.erb`
- Modify: `public/app.css`
- Test: `test/controllers/reports_controller_test.rb`

- [ ] **Step 1: Add navigation assertions**

Append to `test/controllers/reports_controller_test.rb`:

```ruby
test "layout includes dashboard and reports navigation" do
  get "/reports"

  assert_response :success
  assert_select "nav.app-nav a[href='#{root_path}']", text: "Dashboard"
  assert_select "nav.app-nav a[href='#{reports_path}']", text: "Berichte"
end
```

- [ ] **Step 2: Run controller tests to verify navigation test fails**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: navigation selector fails.

- [ ] **Step 3: Update application layout**

Replace the `<body>` section in `app/views/layouts/application.html.erb` with:

```erb
  <body>
    <nav class="app-nav" aria-label="Hauptnavigation">
      <%= link_to "Dashboard", root_path, class: ["app-nav-link", ("active" if current_page?(root_path))] %>
      <%= link_to "Berichte", reports_path, class: ["app-nav-link", ("active" if current_page?(reports_path))] %>
    </nav>

    <main class="app-main">
      <%= yield %>
    </main>
  </body>
```

- [ ] **Step 4: Add responsive styles**

Append to `public/app.css`:

```css
.app-nav {
  display: flex;
  gap: 8px;
  align-items: center;
  margin-bottom: 16px;
  position: sticky;
  top: 0;
  z-index: 10;
  background: color-mix(in srgb, var(--bg) 92%, white);
  padding: 8px 0;
}

.app-nav-link {
  color: var(--muted);
  text-decoration: none;
  border: 1px solid var(--border);
  background: var(--card);
  border-radius: 999px;
  padding: 8px 12px;
  font-size: 14px;
}

.app-nav-link.active {
  color: var(--text);
  border-color: var(--accent);
  background: #fff8db;
}

.app-main {
  width: 100%;
}

.page-header {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  align-items: flex-start;
  margin-bottom: 12px;
}

.page-subtitle {
  margin: -8px 0 0;
  color: var(--muted);
  font-size: 14px;
}

.report-panel,
.empty-state {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 12px;
  margin-bottom: 12px;
}

.report-controls {
  display: grid;
  gap: 12px;
}

.preset-actions,
.date-range-form {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: end;
}

.preset-link,
.date-range-form input,
.date-range-form input[type="submit"] {
  min-height: 38px;
}

.preset-link {
  display: inline-flex;
  align-items: center;
  color: var(--muted);
  text-decoration: none;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px 10px;
}

.preset-link.active {
  color: var(--text);
  border-color: var(--accent);
  background: #fff8db;
}

.date-range-form label {
  display: grid;
  gap: 4px;
  color: var(--muted);
  font-size: 12px;
}

.date-range-form input {
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 8px;
  font: inherit;
}

.date-range-form input[type="submit"] {
  background: var(--text);
  color: white;
  cursor: pointer;
}

.report-message {
  border: 1px solid #ffe066;
  background: #fff8db;
  border-radius: 8px;
  padding: 10px 12px;
  color: #7c5e00;
}

.report-summary-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 10px;
  margin-bottom: 12px;
}

.report-summary-card {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 14px;
}

.report-summary-card span {
  display: block;
  color: var(--muted);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}

.report-summary-card strong {
  display: block;
  margin-top: 4px;
  font-size: 22px;
  font-variant-numeric: tabular-nums;
}

.report-grid {
  display: grid;
  grid-template-columns: minmax(0, 2fr) minmax(220px, 1fr);
  gap: 12px;
}

.panel-heading {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  align-items: baseline;
  margin-bottom: 8px;
}

.panel-heading h2,
.ranking-panel h2,
.ranking-panel h3,
.empty-state h2 {
  margin: 0;
}

.panel-heading span,
.muted-text {
  color: var(--muted);
  font-size: 13px;
}

.chart-panel canvas {
  width: 100% !important;
  height: 320px !important;
}

.ranking-list {
  list-style: none;
  margin: 8px 0 14px;
  padding: 0;
  display: grid;
  gap: 8px;
}

.ranking-list li {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  border-bottom: 1px solid var(--border);
  padding-bottom: 8px;
}

.ranking-list strong {
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}

@media (max-width: 720px) {
  body {
    padding: 12px;
  }

  .report-grid {
    grid-template-columns: 1fr;
  }

  .report-summary-grid {
    grid-template-columns: repeat(2, 1fr);
  }

  .chart-panel canvas {
    height: 280px !important;
  }
}

@media (max-width: 420px) {
  .report-summary-grid {
    grid-template-columns: 1fr;
  }

  .panel-heading {
    display: block;
  }

  .date-range-form {
    display: grid;
  }
}
```

- [ ] **Step 5: Run controller tests**

Run:

```bash
bin/rails test test/controllers/reports_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 5**

Run:

```bash
git add app/views/layouts/application.html.erb public/app.css test/controllers/reports_controller_test.rb
git commit -m "feat: add responsive reports navigation"
```

---

### Task 6: Full Verification And Browser Check

**Files:**
- No planned source edits unless verification reveals a defect.

- [ ] **Step 1: Run focused tests**

Run:

```bash
bin/rails test test/models/energy_report_test.rb test/controllers/reports_controller_test.rb
```

Expected: all tests pass.

- [ ] **Step 2: Run existing related tests**

Run:

```bash
bin/rails test test/models/daily_total_test.rb test/test_aggregator.rb test/controllers/api_controller_test.rb
```

Expected: all tests pass. If existing worktree changes cause failures unrelated to this feature, record the failure and inspect before changing files.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
bin/rails test
```

Expected: all tests pass.

- [ ] **Step 4: Start the Rails server**

Run:

```bash
bin/rails server
```

Expected: server starts and prints a local URL, usually `http://127.0.0.1:3000`.

- [ ] **Step 5: Browser-check desktop**

Open `/reports` in the in-app browser at desktop width.

Expected:

- Navigation shows Dashboard and Berichte.
- Berichte is active on `/reports`.
- Date presets and date fields are visible.
- Summary cards render.
- Daily chart and detail chart are not blank when data exists.
- Empty state renders cleanly when there is no data.

- [ ] **Step 6: Browser-check mobile**

Resize or emulate a narrow viewport around 390px wide.

Expected:

- Navigation remains usable.
- Report controls do not overflow.
- Summary cards stack into two columns or one column depending on width.
- Charts stay inside the viewport.
- Sensor ranking remains readable.

- [ ] **Step 7: Final commit for verification fixes if needed**

If verification required fixes, commit them:

```bash
git add app/models/energy_report.rb app/controllers/reports_controller.rb app/views/reports/index.html.erb app/views/reports/_ranking.html.erb app/views/layouts/application.html.erb app/javascript/controllers/energy_report_controller.js public/app.css test/models/energy_report_test.rb test/controllers/reports_controller_test.rb
git commit -m "fix: polish energy reports verification"
```

If no fixes were needed, do not create an empty commit.

---

## Self-Review Notes

- Spec coverage: the plan covers Rails-first rendering, visible navigation, `/reports`, presets, custom range, mobile layout, `daily_totals`, `samples_5min`, Stimulus Chart.js initialization, empty states, and tests.
- Scope decision: partial current-day data is intentionally out of v1; reports use latest fully aggregated day.
- Type consistency: `EnergyReport::Report` exposes the fields used by controller, view, tests, and chart payload.
- Red-flag scan: no incomplete implementation markers are left for required behavior; optional self-consumption metric is explicitly omitted from v1.
