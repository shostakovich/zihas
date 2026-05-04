# Weather Page Visual Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine the existing `/weather` page so solar irradiance reads as a deliberate piece of information, day forecasts read as forecast cards instead of data tables, and night hours render as `Nacht` instead of `0 W/m²`.

**Architecture:** Add a `WeatherDay` Data class that bundles a date with its forecast records and four aggregates (`temp_min`, `temp_max`, `precip_sum`, `solar_peak`). The controller exposes a list of `WeatherDay` instances to the view. The view template is rewritten section-by-section: current-weather card gets a dedicated solar row, hourly cards put solar in a prominent accent line, day cards get a header with summary line and peak-solar badge above an eight-column three-hour grid. Night-time rendering uses `record.daytime == "night"` everywhere.

**Tech Stack:** Rails (ERB views, Minitest, ActiveRecord), plain CSS with existing CSS variables.

**Spec:** `docs/superpowers/specs/2026-05-04-weather-page-visual-refinement-design.md`

---

## File Structure

**Create:**

- `app/models/weather_day.rb` — `Data.define`-based bundle of a date, its records, and four aggregates. Has a `WeatherDay.from_records(date, records)` factory.
- `test/models/weather_day_test.rb` — unit tests for `from_records` aggregate computation including nil handling.

**Modify:**

- `app/controllers/weather_controller.rb` — replace the raw `group_by(...)` for `@future_weather` with a list of `WeatherDay` instances.
- `app/views/weather/index.html.erb` — rewrite all three sections (current, today, next days).
- `app/assets/stylesheets/application.css` — add an accent CSS variable, restructure `.weather-current-*`, `.weather-hour-*`, and `.weather-day-*` rules for the new layout.
- `test/controllers/weather_controller_test.rb` — extend integration test with new assertions for solar row, night rendering, day-card header, and peak badge omission.

No other files change. No new jobs, no new database columns, no new routes.

---

## Task 1: Add `WeatherDay` aggregate model

**Files:**

- Create: `app/models/weather_day.rb`
- Test: `test/models/weather_day_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/models/weather_day_test.rb`:

```ruby
require "test_helper"

class WeatherDayTest < ActiveSupport::TestCase
  def make_record(timestamp:, temperature:, precipitation: nil, solar: nil, daytime: "day")
    WeatherRecord.new(
      kind: "forecast",
      lat: 52.52, lon: 13.405,
      timestamp: timestamp, daytime: daytime, icon: "clear-day",
      temperature: temperature, precipitation: precipitation, solar: solar
    )
  end

  test "from_records computes min/max temperature" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 6.hours, temperature: 11),
      make_record(timestamp: date.to_time + 12.hours, temperature: 17),
      make_record(timestamp: date.to_time + 18.hours, temperature: 14)
    ]

    day = WeatherDay.from_records(date, records)

    assert_equal 11, day.temp_min
    assert_equal 17, day.temp_max
  end

  test "from_records sums precipitation treating nil as zero" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 6.hours, temperature: 12, precipitation: 0.4),
      make_record(timestamp: date.to_time + 9.hours, temperature: 13, precipitation: nil),
      make_record(timestamp: date.to_time + 12.hours, temperature: 15, precipitation: 1.4)
    ]

    day = WeatherDay.from_records(date, records)

    assert_in_delta 1.8, day.precip_sum, 0.001
  end

  test "from_records picks max solar value" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 9.hours, temperature: 13, solar: 220),
      make_record(timestamp: date.to_time + 12.hours, temperature: 17, solar: 480),
      make_record(timestamp: date.to_time + 15.hours, temperature: 17, solar: 380)
    ]

    day = WeatherDay.from_records(date, records)

    assert_equal 480, day.solar_peak
  end

  test "from_records returns nil solar_peak when every record has nil solar" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 9.hours, temperature: 13),
      make_record(timestamp: date.to_time + 12.hours, temperature: 17)
    ]

    day = WeatherDay.from_records(date, records)

    assert_nil day.solar_peak
  end

  test "from_records exposes the date and the records list" do
    date = Date.new(2026, 5, 6)
    records = [make_record(timestamp: date.to_time + 12.hours, temperature: 15)]

    day = WeatherDay.from_records(date, records)

    assert_equal date, day.date
    assert_equal records, day.records
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rtk rake test TEST=test/models/weather_day_test.rb`
Expected: FAIL with `NameError: uninitialized constant WeatherDay`.

- [ ] **Step 3: Implement `WeatherDay`**

Create `app/models/weather_day.rb`:

```ruby
WeatherDay = Data.define(:date, :records, :temp_min, :temp_max, :precip_sum, :solar_peak) do
  def self.from_records(date, records)
    temperatures = records.map(&:temperature).compact
    solar_values = records.map(&:solar).compact

    new(
      date: date,
      records: records,
      temp_min: temperatures.min,
      temp_max: temperatures.max,
      precip_sum: records.sum { |r| r.precipitation || 0 },
      solar_peak: solar_values.max
    )
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rtk rake test TEST=test/models/weather_day_test.rb`
Expected: 5 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
rtk git add app/models/weather_day.rb test/models/weather_day_test.rb
rtk git commit -m "Add WeatherDay aggregate model"
```

---

## Task 2: Wire `WeatherDay` into `WeatherController`

**Files:**

- Modify: `app/controllers/weather_controller.rb`
- Modify: `test/controllers/weather_controller_test.rb`

- [ ] **Step 1: Add a controller assertion that fails**

Add this test below the existing tests in `test/controllers/weather_controller_test.rb`, inside the same class:

```ruby
test "assigns future weather as WeatherDay instances with aggregates" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 09:00"), daytime: "day",
    icon: "partly-cloudy-day", temperature: 13, precipitation: 0.4, solar: 220)
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day",
    icon: "clear-day", temperature: 17, precipitation: 1.4, solar: 480)

  get "/weather"

  future = controller.view_assigns["future_weather"]
  assert_equal 1, future.length
  assert_equal Date.new(2026, 5, 5), future.first.date
  assert_equal 13, future.first.temp_min
  assert_equal 17, future.first.temp_max
  assert_in_delta 1.8, future.first.precip_sum, 0.001
  assert_equal 480, future.first.solar_peak
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb TESTOPTS="--name=test_assigns_future_weather_as_WeatherDay_instances_with_aggregates"`
Expected: FAIL — `future` is currently a `Hash`, not a list of `WeatherDay`.

- [ ] **Step 3: Update the controller**

Replace the body of `WeatherController#index` in `app/controllers/weather_controller.rb`:

```ruby
class WeatherController < ApplicationController
  def index
    @current_weather = WeatherRecord.current.order(updated_at: :desc).first
    @today_weather = WeatherRecord
      .where(timestamp: Time.zone.today.all_day)
      .where(kind: [ "forecast", "historic" ])
      .order(:timestamp)
    @future_weather = WeatherRecord
      .where(kind: "forecast")
      .where("timestamp > ?", Time.zone.today.end_of_day)
      .order(:timestamp)
      .group_by { |record| record.timestamp.to_date }
      .map { |date, records| WeatherDay.from_records(date, records) }
  end
end
```

- [ ] **Step 4: Run the new test plus the existing controller tests**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: 3 runs, 0 failures. The pre-existing `renders current weather today and next days` test still passes because the view template will be updated in later tasks; for now its assertions still match the unchanged ERB.

If the test that asserts `.weather-day-card` fails because the view iterates `@future_weather` as a hash, leave it failing for now — Task 5 fixes the view. Skip this step's expectation only if so. Confirm by running and looking at the failure message.

If both assertion failures arise from the view iterating a hash, temporarily adjust the existing template to:

```erb
<% @future_weather.each do |day| %>
  <% date = day.date %>
  <% records = day.records %>
  ...
<% end %>
```

This is a stop-gap — Task 5 rewrites the section completely. The point of this step is just to keep the test suite green between tasks.

- [ ] **Step 5: Commit**

```bash
rtk git add app/controllers/weather_controller.rb test/controllers/weather_controller_test.rb app/views/weather/index.html.erb
rtk git commit -m "Use WeatherDay aggregates in WeatherController"
```

---

## Task 3: Current-weather card solar row

**Files:**

- Modify: `app/views/weather/index.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Modify: `test/controllers/weather_controller_test.rb`

- [ ] **Step 1: Add the failing assertions**

Append two tests to `test/controllers/weather_controller_test.rb` inside the same class:

```ruby
test "current weather card renders solar row with W/m² during the day" do
  WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "day",
    icon: "clear-day", temperature: 20.8, condition: "dry",
    wind_speed: 12, relative_humidity: 55, cloud_cover: 88,
    precipitation: 0, pressure_msl: 1012, solar: 320)

  get "/weather"

  assert_select ".weather-current-solar", text: /320 W\/m²/
end

test "current weather card renders Nacht in the solar row at night" do
  WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-04 23:00"), daytime: "night",
    icon: "clear-night", temperature: 12.0, condition: "dry",
    wind_speed: 4, relative_humidity: 70, cloud_cover: 10,
    precipitation: 0, pressure_msl: 1015, solar: 200)

  get "/weather"

  assert_select ".weather-current-solar", text: /Nacht/
  assert_select ".weather-current-solar", text: /W\/m²/, count: 0
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: 2 new failures because `.weather-current-solar` does not exist yet.

- [ ] **Step 3: Update the current-weather section in the view**

In `app/views/weather/index.html.erb`, replace the existing `<section class="weather-current ...">...</section>` block with:

```erb
<% if @current_weather %>
  <section class="weather-current chart-card">
    <div class="weather-current-head">
      <%= image_tag @current_weather.asset_name, class: "weather-current-icon", alt: @current_weather.icon.to_s %>
      <div class="weather-current-main">
        <div class="tile-label">Jetzt</div>
        <div class="weather-current-temp"><%= number_with_precision(@current_weather.temperature, precision: 1, delimiter: ".", separator: ",") %> °C</div>
        <div class="muted-text"><%= @current_weather.condition || "Wetter" %> · Wind <%= number_with_precision(@current_weather.wind_speed || 0, precision: 0, delimiter: ".", separator: ",") %> km/h</div>
      </div>
      <div class="weather-current-facts">
        <div><strong><%= @current_weather.relative_humidity || "—" %>%</strong><br>Luft</div>
        <div><strong><%= @current_weather.cloud_cover || "—" %>%</strong><br>Wolken</div>
        <div><strong><%= number_with_precision(@current_weather.precipitation || 0, precision: 1, delimiter: ".", separator: ",") %> mm</strong><br>Regen</div>
        <div><strong><%= number_with_precision(@current_weather.pressure_msl || 0, precision: 0, delimiter: ".", separator: ",") %></strong><br>hPa</div>
      </div>
    </div>
    <div class="weather-current-solar">
      <span class="weather-solar-label">☀ Solar</span>
      <span class="weather-solar-value">
        <% if @current_weather.daytime == "night" %>
          Nacht
        <% elsif @current_weather.solar %>
          <%= number_with_precision(@current_weather.solar, precision: 0, delimiter: ".", separator: ",") %> W/m²
        <% else %>
          —
        <% end %>
      </span>
    </div>
  </section>
<% end %>
```

- [ ] **Step 4: Add the accent variable and solar row CSS**

In `app/assets/stylesheets/application.css`, in the `:root` block, add the accent line at the end (right before the closing `}`):

```css
  --solar: #f59e0b;
```

Then, append the following rules at the end of the file (after the existing `@media (max-width: 640px)` block):

```css
.weather-current-head {
  display: flex;
  align-items: center;
  gap: 18px;
  width: 100%;
}
.weather-current {
  flex-direction: column;
  align-items: stretch;
}
.weather-current-solar {
  display: flex;
  align-items: baseline;
  gap: 10px;
  margin-top: 12px;
  padding-top: 10px;
  border-top: 1px dashed var(--border);
}
.weather-solar-label {
  color: var(--solar);
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  font-weight: 600;
}
.weather-solar-value {
  font-size: 16px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
```

The new `.weather-current` rule overrides the `flex-direction` from the existing rule because it is later in the cascade. The existing `.weather-current` rule (line 299) stays untouched; the head row keeps its three-column layout via the new `.weather-current-head` wrapper.

- [ ] **Step 5: Run all controller tests**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: all tests pass, including the original `renders current weather today and next days` (the day-night and Nacht assertions for the today row are added in Task 4).

- [ ] **Step 6: Commit**

```bash
rtk git add app/views/weather/index.html.erb app/assets/stylesheets/application.css test/controllers/weather_controller_test.rb
rtk git commit -m "Add solar row to current weather card"
```

---

## Task 4: Today hourly card layout

**Files:**

- Modify: `app/views/weather/index.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Modify: `test/controllers/weather_controller_test.rb`

- [ ] **Step 1: Add the failing assertions**

Append to `test/controllers/weather_controller_test.rb` inside the same class:

```ruby
test "hourly card renders prominent solar value during the day" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-04 13:00"), daytime: "day",
    icon: "partly-cloudy-day", temperature: 18, precipitation: 0,
    solar: 320, wind_speed: 11)

  get "/weather"

  assert_select ".weather-hour-card .weather-hour-solar", text: /320 W\/m²/
end

test "hourly card renders Nacht at night and never a W/m² value" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-04 23:00"), daytime: "night",
    icon: "clear-night", temperature: 11, precipitation: 0,
    solar: 0, wind_speed: 5)

  get "/weather"

  assert_select ".weather-hour-card .weather-hour-solar", text: /Nacht/
  assert_select ".weather-hour-card .weather-hour-solar", text: /W\/m²/, count: 0
end
```

Also remove (or replace) the now-stale assertion in the existing `renders current weather today and next days` test:

```ruby
assert_select ".weather-solar", text: /320 W\/m²/
```

becomes:

```ruby
assert_select ".weather-hour-card .weather-hour-solar", text: /320 W\/m²/
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: 2 new failures because `.weather-hour-solar` does not exist yet, and the existing assertion now also fails.

- [ ] **Step 3: Update the today section in the view**

In `app/views/weather/index.html.erb`, replace the entire `<section class="weather-hour-row" ...>...</section>` block with:

```erb
<div class="section-label">Heute</div>
<section class="weather-hour-row" aria-label="Heute">
  <% @today_weather.each do |record| %>
    <article class="weather-hour-card">
      <div class="weather-hour-top">
        <span><%= record.timestamp.strftime("%H:%M") %></span>
        <span>
          <% if record.precipitation %>
            <%= number_with_precision(record.precipitation, precision: 1, delimiter: ".", separator: ",") %> mm
          <% elsif record.precipitation_probability %>
            <%= record.precipitation_probability %>%
          <% end %>
        </span>
      </div>
      <%= image_tag record.asset_name, class: "weather-hour-icon", alt: record.icon.to_s %>
      <strong><%= number_with_precision(record.temperature, precision: 0, delimiter: ".", separator: ",") %>°</strong>
      <div class="weather-hour-solar<%= record.daytime == "night" ? " is-night" : "" %>">
        <% if record.daytime == "night" %>
          ☾ Nacht
        <% elsif record.solar %>
          ☀ <%= number_with_precision(record.solar, precision: 0, delimiter: ".", separator: ",") %> W/m²
        <% else %>
          Wolken <%= record.cloud_cover || "—" %>%
        <% end %>
      </div>
      <div class="weather-hour-wind">💨 <%= number_with_precision(record.wind_speed || 0, precision: 0, delimiter: ".", separator: ",") %> km/h</div>
    </article>
  <% end %>
</section>
```

- [ ] **Step 4: Update the hourly card CSS**

In `app/assets/stylesheets/application.css`, append at the end of the file:

```css
.weather-hour-solar {
  margin-top: 6px;
  color: var(--solar);
  font-size: 13px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.weather-hour-solar.is-night {
  color: var(--muted);
  font-weight: 500;
}
.weather-hour-wind {
  margin-top: 4px;
  font-size: 11px;
  color: var(--muted);
}
```

- [ ] **Step 5: Run all controller tests**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
rtk git add app/views/weather/index.html.erb app/assets/stylesheets/application.css test/controllers/weather_controller_test.rb
rtk git commit -m "Make solar prominent in today hour cards and render Nacht at night"
```

---

## Task 5: Day cards header and three-hour grid

**Files:**

- Modify: `app/views/weather/index.html.erb`
- Modify: `app/assets/stylesheets/application.css`
- Modify: `test/controllers/weather_controller_test.rb`

- [ ] **Step 1: Add the failing assertions**

Append to `test/controllers/weather_controller_test.rb`:

```ruby
test "day card renders weekday summary line and peak solar badge" do
  [
    { hour: 6, temp: 13, precip: 0.4, solar: 220 },
    { hour: 12, temp: 17, precip: 0.0, solar: 480 },
    { hour: 18, temp: 14, precip: 1.4, solar: 90 }
  ].each do |slot|
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-06 #{format('%02d', slot[:hour])}:00"),
      daytime: "day", icon: "partly-cloudy-day",
      temperature: slot[:temp], precipitation: slot[:precip], solar: slot[:solar])
  end

  get "/weather"

  assert_select ".weather-day-card .weather-day-summary", text: /13.*–.*17.*°C/
  assert_select ".weather-day-card .weather-day-summary", text: /Regen 1,8 mm/
  assert_select ".weather-day-card .weather-day-peak", text: /Spitze 480 W\/m²/
end

test "day card omits peak badge when every record has nil solar" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-06 12:00"), daytime: "day",
    icon: "cloudy", temperature: 12, precipitation: 0)
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-06 18:00"), daytime: "day",
    icon: "cloudy", temperature: 11, precipitation: 0)

  get "/weather"

  assert_select ".weather-day-card .weather-day-peak", count: 0
end

test "day card renders Nacht in slots whose record is at night" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-06 03:00"), daytime: "night",
    icon: "clear-night", temperature: 11)
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-06 12:00"), daytime: "day",
    icon: "clear-day", temperature: 17, solar: 480)

  get "/weather"

  assert_select ".weather-day-slot .weather-day-slot-solar", text: /Nacht/
end
```

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: 3 new failures.

- [ ] **Step 3: Update the next-days section in the view**

In `app/views/weather/index.html.erb`, replace the entire `<section class="weather-days">...</section>` block with:

```erb
<div class="section-label">Nächste Tage</div>
<section class="weather-days">
  <% @future_weather.each do |day| %>
    <article class="weather-day-card">
      <header class="weather-day-head">
        <div>
          <div class="weather-day-name"><strong><%= l(day.date, format: "%A") rescue day.date.to_s %></strong></div>
          <div class="weather-day-summary">
            <%= number_with_precision(day.temp_min, precision: 0, delimiter: ".", separator: ",") %>
            – <%= number_with_precision(day.temp_max, precision: 0, delimiter: ".", separator: ",") %> °C
            · Regen <%= number_with_precision(day.precip_sum, precision: 1, delimiter: ".", separator: ",") %> mm
          </div>
        </div>
        <% if day.solar_peak %>
          <div class="weather-day-peak">☀ Spitze <%= number_with_precision(day.solar_peak, precision: 0, delimiter: ".", separator: ",") %> W/m²</div>
        <% end %>
      </header>
      <div class="weather-day-slots">
        <% day.records.select { |r| (r.timestamp.hour % 3).zero? }.each do |record| %>
          <div class="weather-day-slot">
            <div class="weather-day-slot-time"><%= record.timestamp.strftime("%H") %></div>
            <%= image_tag record.asset_name, class: "weather-day-icon", alt: record.icon.to_s %>
            <strong><%= number_with_precision(record.temperature, precision: 0, delimiter: ".", separator: ",") %>°</strong>
            <div class="weather-day-slot-solar<%= record.daytime == "night" ? " is-night" : "" %>">
              <% if record.daytime == "night" %>
                Nacht
              <% elsif record.solar %>
                <%= number_with_precision(record.solar, precision: 0, delimiter: ".", separator: ",") %> W/m²
              <% else %>
                Wolken <%= record.cloud_cover || "—" %>%
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </article>
  <% end %>
</section>
```

If Task 2's stop-gap edit already exists in this section, this replacement supersedes it.

- [ ] **Step 4: Update the day-card CSS**

In `app/assets/stylesheets/application.css`, append at the end of the file:

```css
.weather-day-head {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 12px;
  flex-wrap: wrap;
  margin-bottom: 10px;
}
.weather-day-name {
  font-size: 15px;
}
.weather-day-summary {
  color: var(--muted);
  font-size: 12px;
  margin-top: 2px;
}
.weather-day-peak {
  color: var(--solar);
  font-size: 12px;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}
.weather-day-slots {
  grid-template-columns: repeat(8, minmax(0, 1fr));
}
.weather-day-slot-time {
  font-size: 11px;
}
.weather-day-slot-solar {
  font-size: 10px;
  color: var(--solar);
  font-variant-numeric: tabular-nums;
  margin-top: 2px;
}
.weather-day-slot-solar.is-night {
  color: var(--muted);
  font-weight: 400;
}
@media (max-width: 640px) {
  .weather-day-slots {
    grid-template-columns: repeat(4, minmax(0, 1fr));
    row-gap: 12px;
  }
}
```

The new `.weather-day-slots` rule overrides the existing `repeat(4, ...)` rule (line 367) because it appears later in the cascade.

- [ ] **Step 5: Run all controller tests**

Run: `rtk rake test TEST=test/controllers/weather_controller_test.rb`
Expected: all tests pass.

- [ ] **Step 6: Run the full test suite**

Run: `rtk rake test`
Expected: 0 failures, 0 errors.

- [ ] **Step 7: Commit**

```bash
rtk git add app/views/weather/index.html.erb app/assets/stylesheets/application.css test/controllers/weather_controller_test.rb
rtk git commit -m "Add header summary and 3h grid to day forecast cards"
```

---

## Self-Review

**Spec coverage** — every spec section maps to a task:

| Spec section | Task |
|---|---|
| Out of Scope | Reflected by absence: no new tables, jobs, configs, dashboards. |
| Current Weather (`weather-current`) | Task 3 |
| Today (`weather-hour-row`) | Task 4 |
| Next Days (`weather-days`) | Task 5 |
| Day-Level Aggregation (controller) | Task 1 (model) + Task 2 (controller) |
| Night Detection | Tasks 3, 4, 5 (each uses `record.daytime == "night"`) |
| CSS | Tasks 3, 4, 5 (each section appends its own rules; accent variable added in Task 3) |
| Tests — controller spec | Task 2 |
| Tests — view spec | Tasks 3, 4, 5 |

**Type consistency** — `WeatherDay.from_records(date, records)` returns a value with fields `date`, `records`, `temp_min`, `temp_max`, `precip_sum`, `solar_peak`. Tests in Tasks 1 and 2 use those exact names. The view template in Task 5 reads `day.date`, `day.temp_min`, `day.temp_max`, `day.precip_sum`, `day.solar_peak`, `day.records`. Consistent.

**CSS class names** introduced and reused:

- `.weather-current-head`, `.weather-current-solar`, `.weather-solar-label`, `.weather-solar-value` — Task 3.
- `.weather-hour-solar` (with `.is-night`), `.weather-hour-wind` — Task 4.
- `.weather-day-head`, `.weather-day-name`, `.weather-day-summary`, `.weather-day-peak`, `.weather-day-slot-time`, `.weather-day-slot-solar` (with `.is-night`) — Task 5.

The view template references in each task match the CSS class names declared in the same task. Test selectors match.

**Placeholder scan** — no `TBD`, no `TODO`, every step contains the actual code or command to run.
