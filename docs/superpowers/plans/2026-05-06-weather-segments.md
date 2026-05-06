# Wetterzusammenfassung in 6h-Segmenten Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the eight 3h slots in each "Nächste Tage" card on `/weather` with four 6h segments (Nacht, Vormittag, Nachmittag, Abend), so notable weather (e.g. a 14:00 thunderstorm) is no longer dropped between sample points. Segments are always visible; clicking one toggles a row of six hour cards below.

**Architecture:** Pure-Ruby aggregation: a new `WeatherSegment` PORO summarizes a 6h slice of `WeatherRecord`s with a severity-ranked icon picker; `WeatherDay#segments` returns four of them in fixed order. The view renders segment tiles + a sibling row of hidden hour-card containers (one per segment). A small Stimulus controller (`weather-segments`) manages single-select toggling client-side. The hour-card markup is extracted into a shared partial reused by the existing "Heute" row and the new expansion. No backend / API / schema changes.

**Tech Stack:** Ruby on Rails 8.1, Minitest, Stimulus, ERB, plain CSS in `application.css`.

---

## Spec

`docs/superpowers/specs/2026-05-06-weather-segments-design.md`

---

## File Structure

**New files:**
- `app/models/weather_segment.rb` — aggregator PORO
- `app/views/weather/_hour_card.html.erb` — shared hour-card partial (extracted from current "Heute" inline markup)
- `app/javascript/controllers/weather_segments_controller.js` — single-select toggle
- `test/models/weather_segment_test.rb` — unit tests
- `test/system/weather_segments_test.rb` — one browser-driven toggle test

**Modified files:**
- `app/models/weather_day.rb` — add `SEGMENTS` constant and `segments` method
- `app/views/weather/index.html.erb` — replace `.weather-day-slots` block with `.weather-day-segments` + `.weather-day-hours`; replace inline "Heute" hour markup with `render "hour_card"`
- `app/assets/stylesheets/application.css` — new segment styles + responsive 2×2 grid
- `test/models/weather_day_test.rb` — add segment-bucketing tests
- `test/controllers/weather_controller_test.rb` — update structural assertions for new markup

`app/controllers/weather_controller.rb`, `app/models/weather_record.rb`, `lib/weather_icon.rb`, `db/schema.rb`, and any API/job files are **unchanged**.

---

## Conventions Used By This Codebase (read before starting)

- **Tests:** Minitest, run with `bin/rails test`. Single file: `bin/rails test test/path/to/file.rb`. Single test by name: `bin/rails test test/path/to/file.rb -n test_name_with_underscores`.
- **System tests:** Selenium + headless Chrome via `test/system/application_system_test_case.rb`. Run all system tests with `bin/rails test:system`. They are slower and live separately.
- **Test fixture clock:** the existing `WeatherControllerTest` freezes time with `travel_to Time.zone.local(2026, 5, 4, 12, 0)` in `setup`. Reuse the same anchor for any new controller-level assertions. The "Nächste Tage" section starts at `Date.tomorrow` (i.e. 2026-05-05 onwards) under that clock.
- **Number formatting in views:** German format via `number_with_precision(value, precision: …, delimiter: ".", separator: ",")`. Match existing usage exactly.
- **Stimulus:** controllers under `app/javascript/controllers/` are auto-registered by `eagerLoadControllersFrom("controllers", application)` in `controllers/index.js`. New file → no manual wiring. Filename `weather_segments_controller.js` ↔ `data-controller="weather-segments"`.
- **Stimulus targets:** existing convention is camelCase target names (e.g. `tileProduced`). Use camelCase: `tile`, `hourRow`, `hours`.
- **Icon assets:** `WeatherIcon.asset_name(icon, daytime)` returns the `weather_<icon>_<day|night>.webp` filename. `WeatherIcon.normalized_icon(icon)` strips `-day`/`-night` and returns one of `clear partly-cloudy cloudy fog wind rain sleet snow hail thunderstorm unknown`. Both are `module_function`s and callable as `WeatherIcon.method(...)`.
- **Commits:** small, focused, plain-English subject in imperative present tense. No co-author footer needed unless the user has been adding one — recent history shows none. RuboCop is configured (`.rubocop.yml`) and previous commits include style fixes; run `bin/rubocop` before each commit if a Ruby file changed.

---

## Task 1: `WeatherSegment` PORO with severity-ranked icon

**Files:**
- Create: `app/models/weather_segment.rb`
- Create: `test/models/weather_segment_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/weather_segment_test.rb
require "test_helper"

class WeatherSegmentTest < ActiveSupport::TestCase
  def make_record(hour:, icon: "clear-day", daytime: "day", temperature: 15, precipitation: nil, solar: nil)
    WeatherRecord.new(
      kind: "forecast",
      lat: 52.52, lon: 13.405,
      timestamp: Time.zone.local(2026, 5, 6, hour),
      icon: icon, daytime: daytime,
      temperature: temperature, precipitation: precipitation, solar: solar
    )
  end

  def segment(records, label: "Nachmittag", hour_range: 12...18)
    WeatherSegment.new(label: label, hour_range: hour_range, records: records)
  end

  test "dominant_icon returns most severe icon across the window" do
    records = [
      make_record(hour: 12, icon: "clear-day"),
      make_record(hour: 13, icon: "partly-cloudy-day"),
      make_record(hour: 14, icon: "thunderstorm"),
      make_record(hour: 15, icon: "clear-day"),
      make_record(hour: 16, icon: "rain"),
      make_record(hour: 17, icon: "clear-day")
    ]
    assert_equal "thunderstorm", segment(records).dominant_icon
  end

  test "dominant_icon falls back to unknown for empty segment" do
    assert_equal "unknown", segment([]).dominant_icon
  end

  test "dominant_icon returns earliest record on severity tie" do
    records = [
      make_record(hour: 12, icon: "rain"),
      make_record(hour: 13, icon: "clear-day"),
      make_record(hour: 14, icon: "rain")
    ]
    # Both rain hours tie; min_by keeps the first one encountered.
    assert_equal "rain", segment(records).dominant_icon
  end

  test "temp_min and temp_max ignore nil temperatures" do
    records = [
      make_record(hour: 12, temperature: 11),
      make_record(hour: 13, temperature: nil),
      make_record(hour: 14, temperature: 17)
    ]
    seg = segment(records)
    assert_equal 11, seg.temp_min
    assert_equal 17, seg.temp_max
  end

  test "precip_sum treats nil as zero" do
    records = [
      make_record(hour: 12, precipitation: 0.4),
      make_record(hour: 13, precipitation: nil),
      make_record(hour: 14, precipitation: 1.4)
    ]
    assert_in_delta 1.8, segment(records).precip_sum, 0.001
  end

  test "avg_solar_w_per_m2 averages over records with solar, ignoring nils" do
    # solar is kWh/m² over 60 min for forecasts; .solar_w_per_m2 returns kWh*1000.
    records = [
      make_record(hour: 12, solar: 0.30),
      make_record(hour: 13, solar: nil),
      make_record(hour: 14, solar: 0.50)
    ]
    # mean of 300 and 500 = 400
    assert_in_delta 400.0, segment(records).avg_solar_w_per_m2, 0.001
  end

  test "avg_solar_w_per_m2 returns nil when no records have solar" do
    records = [make_record(hour: 12, solar: nil), make_record(hour: 13, solar: nil)]
    assert_nil segment(records).avg_solar_w_per_m2
  end

  test "all_night? is true only when at least one record exists and all are night" do
    night = [
      make_record(hour: 0, daytime: "night"),
      make_record(hour: 1, daytime: "night")
    ]
    mixed = [
      make_record(hour: 18, daytime: "day"),
      make_record(hour: 19, daytime: "night")
    ]
    assert segment(night, label: "Nacht", hour_range: 0...6).all_night?
    refute segment(mixed, label: "Abend", hour_range: 18...24).all_night?
    refute segment([], label: "Nacht", hour_range: 0...6).all_night?
  end

  test "dominant_daytime picks the daytime of the most-severe-icon record" do
    records = [
      make_record(hour: 18, icon: "clear-day", daytime: "day"),
      make_record(hour: 19, icon: "thunderstorm", daytime: "night"),
      make_record(hour: 20, icon: "clear-night", daytime: "night")
    ]
    seg = segment(records, label: "Abend", hour_range: 18...24)
    assert_equal "night", seg.dominant_daytime
  end

  test "asset_name combines dominant icon and dominant daytime" do
    records = [
      make_record(hour: 12, icon: "clear-day", daytime: "day"),
      make_record(hour: 14, icon: "thunderstorm", daytime: "day")
    ]
    assert_equal "weather_thunderstorm_day.webp", segment(records).asset_name
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/weather_segment_test.rb`
Expected: FAIL with `NameError: uninitialized constant WeatherSegment`.

- [ ] **Step 3: Implement `WeatherSegment`**

```ruby
# app/models/weather_segment.rb
require "weather_icon"

WeatherSegment = Data.define(:label, :hour_range, :records) do
  ICON_SEVERITY = %w[
    thunderstorm hail snow sleet rain wind fog cloudy partly-cloudy clear unknown
  ].freeze

  def temp_min
    records.map(&:temperature).compact.min
  end

  def temp_max
    records.map(&:temperature).compact.max
  end

  def precip_sum
    records.sum { |r| r.precipitation || 0 }
  end

  def avg_solar_w_per_m2
    values = records.filter_map(&:solar_w_per_m2)
    return nil if values.empty?
    values.sum / values.size
  end

  def all_night?
    records.any? && records.all? { |r| r.daytime == "night" }
  end

  def dominant_icon
    return "unknown" if records.empty?
    icons = records.map { |r| WeatherIcon.normalized_icon(r.icon) }
    icons.min_by { |i| ICON_SEVERITY.index(i) || ICON_SEVERITY.size }
  end

  def dominant_daytime
    target = dominant_icon
    record = records.find { |r| WeatherIcon.normalized_icon(r.icon) == target } || records.first
    record&.daytime || "day"
  end

  def asset_name
    WeatherIcon.asset_name(dominant_icon, dominant_daytime)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/weather_segment_test.rb`
Expected: all 9 tests pass.

- [ ] **Step 5: Run RuboCop on the new files**

Run: `bin/rubocop app/models/weather_segment.rb test/models/weather_segment_test.rb`
Expected: no offenses (or auto-correct: `bin/rubocop -A` and re-run tests).

- [ ] **Step 6: Commit**

```bash
git add app/models/weather_segment.rb test/models/weather_segment_test.rb
git commit -m "Add WeatherSegment with severity-ranked icon picker"
```

---

## Task 2: `WeatherDay#segments` returning four segments in fixed order

**Files:**
- Modify: `app/models/weather_day.rb`
- Modify: `test/models/weather_day_test.rb`

- [ ] **Step 1: Add the failing tests**

Append to `test/models/weather_day_test.rb` inside `class WeatherDayTest`:

```ruby
test "segments returns four segments in display order with correct labels and hour ranges" do
  date = Date.new(2026, 5, 6)
  records = (0..23).map do |h|
    make_record(timestamp: date.to_time + h.hours, temperature: 10 + h, daytime: h < 6 ? "night" : "day")
  end

  day = WeatherDay.from_records(date, records)
  segs = day.segments

  assert_equal 4, segs.size
  assert_equal %w[Nacht Vormittag Nachmittag Abend], segs.map(&:label)
  assert_equal [0...6, 6...12, 12...18, 18...24], segs.map(&:hour_range)
  assert_equal 6, segs[0].records.size
  assert_equal 6, segs[1].records.size
  assert_equal 6, segs[2].records.size
  assert_equal 6, segs[3].records.size
end

test "segments place a 06:00 record into Vormittag, not Nacht" do
  date = Date.new(2026, 5, 6)
  records = [
    make_record(timestamp: date.to_time + 5.hours, temperature: 8, daytime: "night"),
    make_record(timestamp: date.to_time + 6.hours, temperature: 9, daytime: "day")
  ]
  segs = WeatherDay.from_records(date, records).segments

  assert_equal 1, segs[0].records.size # Nacht: 05:00 only
  assert_equal 1, segs[1].records.size # Vormittag: 06:00 only
  assert_equal 0, segs[2].records.size
  assert_equal 0, segs[3].records.size
end

test "segments are present even when day has no records" do
  segs = WeatherDay.from_records(Date.new(2026, 5, 6), []).segments
  assert_equal 4, segs.size
  assert(segs.all? { |s| s.records.empty? })
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/weather_day_test.rb -n test_segments_returns_four_segments_in_display_order_with_correct_labels_and_hour_ranges`
Expected: FAIL with `NoMethodError: undefined method 'segments'`.

- [ ] **Step 3: Add the `segments` method to `WeatherDay`**

Edit `app/models/weather_day.rb`. The current file ends with `def date_label … end / end`. Add the constant and method **inside the `Data.define` block**, after `date_label`:

```ruby
SEGMENTS = [
  ["Nacht",       0...6],
  ["Vormittag",   6...12],
  ["Nachmittag", 12...18],
  ["Abend",      18...24]
].freeze

def segments
  by_label = records.group_by do |r|
    label, _ = SEGMENTS.find { |_, range| range.cover?(r.timestamp.hour) }
    label
  end
  SEGMENTS.map do |label, range|
    WeatherSegment.new(label: label, hour_range: range, records: by_label[label] || [])
  end
end
```

(Constants inside a `Data.define do … end` block become constants on the resulting class — same scoping as `WEEKDAY_LABELS_DE` already in this file.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/weather_day_test.rb`
Expected: all `WeatherDay` tests pass (existing + new).

- [ ] **Step 5: Run RuboCop**

Run: `bin/rubocop app/models/weather_day.rb test/models/weather_day_test.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/models/weather_day.rb test/models/weather_day_test.rb
git commit -m "Add WeatherDay#segments returning four 6h aggregates"
```

---

## Task 3: Extract shared `_hour_card` partial (refactor "Heute" loop)

This refactor lands first so the segment expansion in Task 4 can render the same partial without duplicating markup.

**Files:**
- Create: `app/views/weather/_hour_card.html.erb`
- Modify: `app/views/weather/index.html.erb`

- [ ] **Step 1: Create the partial with the existing hour-card markup**

```erb
<%# app/views/weather/_hour_card.html.erb -%>
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
      <%= image_tag "weather_clear_night.webp", class: "weather-inline-icon", alt: "" %>
      Nacht
    <% elsif record.solar_w_per_m2 %>
      <%= image_tag "weather_clear_day.webp", class: "weather-inline-icon", alt: "" %>
      <%= number_with_precision(record.solar_w_per_m2, precision: 0, delimiter: ".", separator: ",") %> W/m²
    <% else %>
      <%= image_tag "weather_clear_day.webp", class: "weather-inline-icon", alt: "" %>
      — W/m²
    <% end %>
  </div>
  <div class="weather-hour-wind">💨 <%= number_with_precision(record.wind_speed || 0, precision: 0, delimiter: ".", separator: ",") %> km/h</div>
</article>
```

- [ ] **Step 2: Replace the inline "Heute" loop in `index.html.erb` to use the partial**

In `app/views/weather/index.html.erb`, replace the entire `<% @today_weather.each do |record| %> … <% end %>` block (currently lines ~46–74) with:

```erb
<% @today_weather.each do |record| %>
  <%= render "hour_card", record: record %>
<% end %>
```

The surrounding `<section class="weather-hour-row" aria-label="Heute">` wrapper stays.

- [ ] **Step 3: Run controller tests to verify HTML is byte-identical**

Run: `bin/rails test test/controllers/weather_controller_test.rb`
Expected: all existing tests pass with no changes — the assertions like `".weather-hour-card .weather-hour-solar", text: /320 W\/m²/` continue to match because the rendered markup is the same.

- [ ] **Step 4: Run RuboCop on touched files**

Run: `bin/rubocop app/views/weather/index.html.erb` (will be a no-op for ERB, but harmless)
Expected: no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/views/weather/_hour_card.html.erb app/views/weather/index.html.erb
git commit -m "Extract weather hour card into shared partial"
```

---

## Task 4: Replace day-card slot grid with segment tiles + hidden hour rows

**Files:**
- Modify: `app/views/weather/index.html.erb`
- Modify: `test/controllers/weather_controller_test.rb`

- [ ] **Step 1: Replace the `.weather-day-slots` block in the `@future_weather.each` loop**

In `app/views/weather/index.html.erb`, find:

```erb
<div class="weather-day-slots">
  <% day.records.select { |r| (r.timestamp.hour % 3).zero? }.each do |record| %>
    <div class="weather-day-slot">
      …
    </div>
  <% end %>
</div>
```

Replace **the whole `<div class="weather-day-slots">…</div>`** with:

```erb
<div class="weather-day-segments"
     data-controller="weather-segments"
     data-weather-segments-day-value="<%= day.date.iso8601 %>">
  <% day.segments.each_with_index do |segment, idx| %>
    <button type="button"
            class="weather-segment"
            data-weather-segments-target="tile"
            data-action="click->weather-segments#toggle"
            data-segment-index="<%= idx %>"
            aria-expanded="false"
            aria-controls="seg-<%= day.date.iso8601 %>-<%= idx %>">
      <div class="weather-segment-label"><%= segment.label %></div>
      <%= image_tag segment.asset_name, class: "weather-segment-icon", alt: segment.dominant_icon.to_s %>
      <strong class="weather-segment-temp">
        <%= number_with_precision(segment.temp_min || 0, precision: 0, delimiter: ".", separator: ",") %>
        – <%= number_with_precision(segment.temp_max || 0, precision: 0, delimiter: ".", separator: ",") %>°
      </strong>
      <% if segment.precip_sum.positive? %>
        <div class="weather-segment-precip">
          <%= number_with_precision(segment.precip_sum, precision: 1, delimiter: ".", separator: ",") %> mm
        </div>
      <% end %>
      <div class="weather-segment-solar<%= segment.all_night? ? " is-night" : "" %>">
        <% if segment.all_night? %>
          Nacht
        <% elsif segment.avg_solar_w_per_m2 %>
          <%= number_with_precision(segment.avg_solar_w_per_m2, precision: 0, delimiter: ".", separator: ",") %> W/m²
        <% else %>
          — W/m²
        <% end %>
      </div>
    </button>
  <% end %>
</div>

<div class="weather-day-hours" data-weather-segments-target="hours">
  <% day.segments.each_with_index do |segment, idx| %>
    <div class="weather-day-hour-row"
         id="seg-<%= day.date.iso8601 %>-<%= idx %>"
         data-weather-segments-target="hourRow"
         data-segment-index="<%= idx %>"
         hidden>
      <% segment.records.each do |record| %>
        <%= render "hour_card", record: record %>
      <% end %>
    </div>
  <% end %>
</div>
```

The day-card header (`<header class="weather-day-head">…</header>`) above this block is unchanged.

- [ ] **Step 2: Update `weather_controller_test.rb` assertions**

The existing test `"renders current weather today and next days"` does not assert anything about `.weather-day-slot`. It does assert `assert_select ".weather-day-card", minimum: 1`, which still passes. But add coverage for the new structure and severity behaviour. Append:

```ruby
test "next-day card renders four segment tiles" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
    icon: "clear-day", temperature: 20)

  get "/weather"

  assert_select ".weather-day-card .weather-day-segments .weather-segment", count: 4
  assert_select ".weather-day-card .weather-segment-label", text: "Nacht"
  assert_select ".weather-day-card .weather-segment-label", text: "Vormittag"
  assert_select ".weather-day-card .weather-segment-label", text: "Nachmittag"
  assert_select ".weather-day-card .weather-segment-label", text: "Abend"
end

test "Nachmittag segment surfaces a 14:00 thunderstorm icon" do
  # 12:00 and 15:00 sunny would hide the storm in the old 3h grid; segment uses
  # severity ranking so the thunderstorm icon wins.
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day",
    icon: "clear-day", temperature: 22)
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
    icon: "thunderstorm", temperature: 19)
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 15:00"), daytime: "day",
    icon: "clear-day", temperature: 23)

  get "/weather"

  # Find the Nachmittag tile by its label and assert its icon image src
  assert_select ".weather-segment", text: /Nachmittag/ do
    assert_select "img.weather-segment-icon[src*=?]", "weather_thunderstorm_day"
  end
end

test "next-day card emits hour rows hidden by default" do
  WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
    timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
    icon: "clear-day", temperature: 20)

  get "/weather"

  # Each hour-row is rendered server-side with the `hidden` attribute so the
  # default state (no segment selected) shows only the four tiles.
  assert_select ".weather-day-hours .weather-day-hour-row[hidden]", count: 4
end
```

- [ ] **Step 3: Run controller tests**

Run: `bin/rails test test/controllers/weather_controller_test.rb`
Expected: all tests pass — both existing ones (still rendering `.weather-day-card` etc.) and the three new ones.

- [ ] **Step 4: Run RuboCop on touched files**

Run: `bin/rubocop test/controllers/weather_controller_test.rb`
Expected: no offenses.

- [ ] **Step 5: Commit**

```bash
git add app/views/weather/index.html.erb test/controllers/weather_controller_test.rb
git commit -m "Render Nächste Tage as 6h segment tiles with hidden hour rows"
```

---

## Task 5: Stimulus controller `weather-segments` for single-select toggle

**Files:**
- Create: `app/javascript/controllers/weather_segments_controller.js`
- Create: `test/system/weather_segments_test.rb`

- [ ] **Step 1: Implement the controller**

```javascript
// app/javascript/controllers/weather_segments_controller.js
import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="weather-segments"
// One instance per day-card. Manages single-select expansion of the four
// segment tiles into the matching hidden hour-row. Click same tile to
// collapse; click another to switch.
export default class extends Controller {
  static targets = ["tile", "hourRow"]

  connect() {
    this.selectedIndex = null
    this.render()
  }

  toggle(event) {
    const idx = Number(event.currentTarget.dataset.segmentIndex)
    this.selectedIndex = (this.selectedIndex === idx) ? null : idx
    this.render()
  }

  render() {
    this.tileTargets.forEach((tile) => {
      const idx = Number(tile.dataset.segmentIndex)
      const open = idx === this.selectedIndex
      tile.classList.toggle("is-selected", open)
      tile.setAttribute("aria-expanded", open ? "true" : "false")
    })
    this.hourRowTargets.forEach((row) => {
      const idx = Number(row.dataset.segmentIndex)
      const open = idx === this.selectedIndex
      row.hidden = !open
    })
  }
}
```

- [ ] **Step 2: Write the system test**

```ruby
# test/system/weather_segments_test.rb
require "application_system_test_case"

class WeatherSegmentsTest < ApplicationSystemTestCase
  setup do
    WeatherRecord.delete_all
    travel_to Time.zone.local(2026, 5, 4, 12, 0)

    # One forecast hour in each segment of 2026-05-05 (a "Nächste Tage" day).
    {
      "02:00" => "Nacht",
      "08:00" => "Vormittag",
      "14:00" => "Nachmittag",
      "20:00" => "Abend"
    }.each_key do |hhmm|
      WeatherRecord.create!(
        kind: "forecast", lat: 52.52, lon: 13.405,
        timestamp: Time.zone.parse("2026-05-05 #{hhmm}"),
        daytime: hhmm.start_with?("0") && hhmm < "06" ? "night" : "day",
        icon: "clear-day", temperature: 15
      )
    end
  end

  teardown { travel_back }

  test "clicking a segment expands its hour row, clicking again collapses, switching swaps" do
    visit "/weather"

    # Default: all four hour rows hidden.
    assert_selector ".weather-day-hours .weather-day-hour-row", count: 4, visible: :hidden

    # Click Nachmittag (segment-index=2 within the first day card).
    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="2"]').click
    end

    # Nachmittag's row visible; the other three still hidden.
    within first(".weather-day-hours") do
      assert_selector '.weather-day-hour-row[data-segment-index="2"]', visible: :visible
      assert_selector '.weather-day-hour-row[data-segment-index="0"]', visible: :hidden
      assert_selector '.weather-day-hour-row[data-segment-index="1"]', visible: :hidden
      assert_selector '.weather-day-hour-row[data-segment-index="3"]', visible: :hidden
    end

    # Click Nachmittag again → collapsed.
    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="2"]').click
    end
    assert_selector ".weather-day-hours .weather-day-hour-row", count: 4, visible: :hidden

    # Click Vormittag, then Nachmittag → only Nachmittag visible.
    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="1"]').click
    end
    within first(".weather-day-hours") do
      assert_selector '.weather-day-hour-row[data-segment-index="1"]', visible: :visible
    end
    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="2"]').click
    end
    within first(".weather-day-hours") do
      assert_selector '.weather-day-hour-row[data-segment-index="2"]', visible: :visible
      assert_selector '.weather-day-hour-row[data-segment-index="1"]', visible: :hidden
    end
  end
end
```

- [ ] **Step 3: Run the system test**

Run: `bin/rails test:system TEST=test/system/weather_segments_test.rb`
Expected: 1 run, 0 failures. (System tests are slower; first run also boots Chrome.)

- [ ] **Step 4: Run unit tests to confirm nothing else broke**

Run: `bin/rails test`
Expected: all tests pass.

- [ ] **Step 5: Run RuboCop**

Run: `bin/rubocop test/system/weather_segments_test.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/controllers/weather_segments_controller.js test/system/weather_segments_test.rb
git commit -m "Add weather-segments Stimulus controller with single-select toggle"
```

---

## Task 6: CSS for segment tiles, expanded state, and 2×2 mobile layout

**Files:**
- Modify: `app/assets/stylesheets/application.css`

- [ ] **Step 1: Add the segment styles next to the existing weather rules**

Open `app/assets/stylesheets/application.css` and **find the `.weather-day-slots` rule** (around line 387). Leave the existing rule and the inner `.weather-day-slot` rules in place for now (they will become dead code after this task, but removing them is part of Step 3 — don't conflate the changes).

Below `.weather-day-peak` and any related rules (i.e. just before any `@media` blocks that target the weather section, or at the end of the weather section), add:

```css
.weather-day-segments {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 0.5rem;
}

.weather-segment {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 0.25rem;
  padding: 0.6rem 0.4rem;
  border: 0;
  border-radius: 12px;
  background: rgba(255, 255, 255, 0.04);
  color: inherit;
  cursor: pointer;
  font: inherit;
  text-align: center;
}

.weather-segment:hover {
  background: rgba(255, 255, 255, 0.08);
}

.weather-segment.is-selected {
  background: rgba(255, 255, 255, 0.12);
  outline: 2px solid currentColor;
  outline-offset: -2px;
}

.weather-segment-label {
  font-size: 0.85rem;
  opacity: 0.8;
}

.weather-segment-icon {
  width: 3rem;
  height: 3rem;
}

.weather-segment-temp {
  font-size: 1.05rem;
}

.weather-segment-precip,
.weather-segment-solar {
  font-size: 0.8rem;
  opacity: 0.85;
}

.weather-segment-solar.is-night {
  opacity: 0.6;
}

.weather-day-hours {
  margin-top: 0.5rem;
}

.weather-day-hour-row {
  display: flex;
  gap: 0.5rem;
  overflow-x: auto;
  padding: 0.25rem 0;
}

.weather-day-hour-row .weather-hour-card {
  flex: 0 0 auto;
}

@media (max-width: 640px) {
  .weather-day-segments {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .weather-segment-icon {
    width: 3.25rem;
    height: 3.25rem;
  }
}
```

(Tile/icon sizing values match the visual review goal of "noticeably larger than current 3h slots" — current `.weather-day-icon` is sized in the existing rules; the 3rem/3.25rem values are roughly 1.5× that. If a final visual pass tunes them, do it as a separate commit.)

- [ ] **Step 2: Remove the now-unused `.weather-day-slots` and `.weather-day-slot*` rules**

These class names are no longer rendered (the view now emits `.weather-day-segments` / `.weather-segment`). In `application.css`, delete:

- `.weather-day-slots { … }` (both occurrences flagged at lines ~387 and ~489 in the current file — verify by searching)
- `.weather-day-slot { … }`
- `.weather-day-icon { … }`
- `.weather-day-slot strong { … }`
- `.weather-day-slot-time` / `.weather-day-slot-solar*` if present

Use a grep to confirm no remaining ERB still uses them:

```bash
grep -rE "weather-day-slot|weather-day-icon" app/views app/javascript
```

Expected: zero matches.

- [ ] **Step 3: Run the full test suite**

Run: `bin/rails test && bin/rails test:system TEST=test/system/weather_segments_test.rb`
Expected: all green. CSS changes don't break controller tests; the system test continues to pass because visibility is driven by the `hidden` attribute, not CSS.

- [ ] **Step 4: Manual visual check**

Start the dev server: `bin/dev`
Open: `http://localhost:3000/weather`
Expected:
- "Nächste Tage" cards show 4 segment tiles in a row on desktop, 2×2 on mobile (resize browser below 640px to confirm).
- Tile icons visibly larger than they were as 3h slots.
- Clicking a tile shows a row of 6 hour cards below the segment row; the tile is highlighted.
- Clicking a different tile switches the highlighted tile and the visible hour row.
- Clicking the same tile again collapses (no segment highlighted, no hour row visible).
- Reload — collapsed default returns.

If something looks off (e.g. icon too small, contrast wrong), tune values inline and re-run the manual check; commit the tweak as a follow-up patch.

- [ ] **Step 5: RuboCop (no Ruby changes, but run as a final sanity check)**

Run: `bin/rubocop`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "Style 6h weather segment tiles and 2x2 mobile grid"
```

---

## Final Verification

- [ ] **Run the full test suite once more**

Run: `bin/rails test && bin/rails test:system`
Expected: 0 failures, 0 errors across unit, integration, and system tests.

- [ ] **Confirm git log**

Run: `git log --oneline main..HEAD`
Expected: six commits in order:

```
… Style 6h weather segment tiles and 2x2 mobile grid
… Add weather-segments Stimulus controller with single-select toggle
… Render Nächste Tage as 6h segment tiles with hidden hour rows
… Extract weather hour card into shared partial
… Add WeatherDay#segments returning four 6h aggregates
… Add WeatherSegment with severity-ranked icon picker
```

- [ ] **Confirm spec coverage**

Skim `docs/superpowers/specs/2026-05-06-weather-segments-design.md`. Each section has a corresponding task above:

| Spec section | Implemented by |
|--------------|----------------|
| Segment Definition (4 windows) | Task 2 (`SEGMENTS` constant) |
| Data Model (`WeatherSegment` PORO) | Task 1 |
| Severity ranking | Task 1 (`ICON_SEVERITY` + tests) |
| Avg solar | Task 1 (`avg_solar_w_per_m2` + test) |
| `all_night?` / Nacht rendering | Task 1 + Task 4 (view branch) |
| `dominant_daytime` | Task 1 |
| View (segment tiles + hour rows) | Task 4 |
| Shared `_hour_card` partial | Task 3 |
| Stimulus controller (single-select toggle) | Task 5 |
| Styling (4-col / 2×2 mobile, larger icons, selected state) | Task 6 |
| Edge cases (empty segment, all night, mixed daytime) | Task 1 (unit tests) |
| Tests outlined in spec | Tasks 1, 2, 4, 5 |
| `WeatherController#index` unchanged | confirmed (no task touches it) |
