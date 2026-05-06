# Design: Wetterzusammenfassung in 6h-Segmenten (Nächste Tage)

## Overview

Restructure the per-day cards in the "Nächste Tage" section of the weather page so each day is summarized by **four 6-hour segments** (Nacht, Vormittag, Nachmittag, Abend) instead of a fixed grid of eight 3-hour slots.

Why: the current 3h grid samples a single hour (00, 03, 06, 09, …) and discards the others. A thunderstorm at 14:00 vanishes between a sunny 12:00 and a sunny 15:00. Each segment instead aggregates all six hours in its window and surfaces the most notable weather.

The four segment tiles are always visible. Clicking a segment expands the six hourly cards for that segment below the row. Single-select: clicking the same segment collapses it; clicking a different segment switches. Default state has no segment selected.

## Goals

- Replace the 3h slot grid in each "Nächste Tage" card with a row of four segment tiles plus an expandable hour-detail row.
- Each segment shows the most notable weather across its six hours (severity-ranked icon), so events like thunderstorms cannot be hidden between sample points.
- 4-in-a-row layout on desktop, 2×2 grid on mobile, with larger weather icons than the current 3h slots.
- Per-segment hour detail uses the existing hour-card visual format (time, icon, temp, solar, wind), reused as-is.
- Toggle state is per-day-card and client-side only (no URL/cookie persistence).

## Non-goals

- "Heute" hour row stays as-is. It is already hourly, so no information is lost; past hours are already hidden, so segment aggregation would be partial and confusing.
- Current weather card is unchanged.
- No new persisted state, no API changes, no backend data changes.
- No animation/keyboard navigation beyond what `<button>` gives for free.
- No segment view on the historic/range pages (this change is scoped to the forecast section).

## Segment Definition

Local-time, half-open intervals on the day:

| Segment      | Hours       |
|--------------|-------------|
| Nacht        | 00:00–06:00 |
| Vormittag    | 06:00–12:00 |
| Nachmittag   | 12:00–18:00 |
| Abend        | 18:00–24:00 |

A segment contains all `WeatherRecord`s whose `timestamp.hour` falls in its window. With hourly forecasts, a segment normally has six records. The aggregation code tolerates fewer, but in the "Nächste Tage" section (strictly future days) every segment should be complete.

## Data Model

No schema or persistence changes. New PORO `WeatherSegment` aggregates a slice of records that `WeatherDay` already holds.

```ruby
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
    icons = records.map { |r| WeatherIcon.normalized_icon(r.icon) }
    return "unknown" if icons.empty?
    icons.min_by { |i| ICON_SEVERITY.index(i) || ICON_SEVERITY.size }
  end

  def dominant_daytime
    # Pick the daytime of the most-severe-icon record, so the icon asset
    # matches the chosen weather event's actual lighting.
    target = dominant_icon
    record = records.find { |r| WeatherIcon.normalized_icon(r.icon) == target } || records.first
    record.daytime
  end

  def asset_name
    WeatherIcon.asset_name(dominant_icon, dominant_daytime)
  end
end
```

`WeatherDay` gains a `segments` method that always returns four `WeatherSegment`s in display order:

```ruby
SEGMENTS = [
  ["Nacht",       0...6],
  ["Vormittag",   6...12],
  ["Nachmittag", 12...18],
  ["Abend",      18...24]
].freeze

def segments
  by_segment = records.group_by { |r| SEGMENTS.find { |_, range| range.cover?(r.timestamp.hour) }&.first }
  SEGMENTS.map do |label, range|
    WeatherSegment.new(label: label, hour_range: range, records: by_segment[label] || [])
  end
end
```

### Severity ranking

```
thunderstorm > hail > snow > sleet > rain > wind > fog > cloudy > partly-cloudy > clear > unknown
```

Rationale: most actionable / surprising weather first. `wind` ranks below precipitation but above pure cloud states because the icon set treats it as a notable condition (it has its own asset). `unknown` is the floor.

If two icons tie on severity, the natural ordering of `min_by` keeps the first occurrence in the records array, i.e. the earliest hour. We deliberately don't tiebreak by frequency; the goal is "what is the most notable thing in this window" and any thunderstorm hour in a 6h window should win, regardless of how many sunny hours surround it.

### Avg solar

`avg_solar_w_per_m2` is the **arithmetic mean of `WeatherRecord#solar_w_per_m2`** across records that have a solar value. For 60-minute forecast records this is the mean of per-hour average power densities, which is itself the segment's average power density. Records with `solar.nil?` are excluded from the average rather than counted as zero, matching the current view's "—" behaviour for missing data.

For Nacht, the records typically all have `daytime: "night"`. The view checks `segment.all_night?` and renders "Nacht" instead of a number.

## View

`app/views/weather/index.html.erb`, "Nächste Tage" `<article class="weather-day-card">`:

The current `<div class="weather-day-slots">…</div>` block is replaced by:

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
        <%= number_with_precision(segment.temp_min, precision: 0, delimiter: ".", separator: ",") %>
        – <%= number_with_precision(segment.temp_max, precision: 0, delimiter: ".", separator: ",") %>°
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
    <div class="weather-day-hour-row" id="seg-<%= day.date.iso8601 %>-<%= idx %>"
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

The existing hour-card markup (currently inlined in the "Heute" section) is extracted into a shared partial `app/views/weather/_hour_card.html.erb` so both the "Heute" row and the segment expansion render identical hour cards.

The day-card header (weekday/date, temp range, precip sum, solar peak) is unchanged.

## Stimulus Controller

New `app/javascript/controllers/weather_segments_controller.js`:

- Targets: `tile` (the four buttons), `hourRow` (the four hidden hour-card rows), `hours` (the wrapper around the hour rows).
- State: a single `selectedIndex` on the controller instance, initialized to `null`.
- `toggle(event)`: read `event.currentTarget.dataset.segmentIndex`, then:
  - if equal to `selectedIndex` → set to `null` (collapse).
  - else → set to the new index.
- After updating state, iterate tiles and hour rows: tile gets `is-selected` + `aria-expanded` matching its state; hour row toggles the `hidden` attribute.
- No persistence. Page reload returns to default (all collapsed).

State is per-controller-instance, i.e. per day-card, so opening a segment on one day does not affect other days.

## Styling

All weather styles currently live in `app/assets/stylesheets/application.css` next to the existing `.weather-hour-row`, `.weather-day-card`, `.weather-day-slots`, etc. The new rules are added in the same file in the weather section.

- `.weather-day-segments`: 4-column CSS grid on desktop. On mobile, 2-column grid (auto-flowing into 2 rows of 2). The breakpoint uses the existing mobile media query in `application.css` (currently `@media (max-width: 420px)` for the most compact layout; if 4-in-a-row already crowds at the 640px breakpoint during visual review, drop to 2×2 there instead). Tile gap matches existing day-card grid spacing.
- `.weather-segment`: button reset (no border/background by default), padded, rounded corners, centered content, vertical stack (label / icon / temp / precip / solar). Icon size noticeably larger than the current `.weather-day-icon` (target ~3rem vs. current ~2rem) — exact value tuned alongside the visual review.
- `.weather-segment.is-selected`: highlighted background and a thin underline / accent border to signal the open state. Choose visuals consistent with the existing chart-card highlight style.
- `.weather-day-hour-row[hidden]`: hidden via the HTML `hidden` attribute (no extra CSS needed beyond ensuring no `display` rule overrides it). When visible, lays out the six hour cards as a horizontally scrollable row matching `.weather-hour-row` from "Heute".
- The segment row remains visible at all times; hour rows render below it. There is no animation on open/close (consistent with existing UI's lack of motion).

## Touched Files

| File | Change |
|------|--------|
| `app/models/weather_segment.rb` | New: aggregator PORO described above. |
| `app/models/weather_day.rb` | Add `segments` method and `SEGMENTS` constant. No removal of existing fields. |
| `app/views/weather/index.html.erb` | Replace `.weather-day-slots` block with segments + hour-rows; render shared `_hour_card` partial. |
| `app/views/weather/_hour_card.html.erb` | New: extracted hour card markup, used by "Heute" row and segment expansion. |
| `app/views/weather/index.html.erb` ("Heute" loop) | Replace inline hour markup with `render "hour_card"`. |
| `app/javascript/controllers/weather_segments_controller.js` | New: toggle controller. Auto-registered by `eagerLoadControllersFrom("controllers", …)` in `controllers/index.js`; no manual wiring needed. |
| `app/assets/stylesheets/application.css` | New `.weather-day-segments`, `.weather-segment`, `.weather-segment.is-selected`, `.weather-day-hours`, `.weather-day-hour-row` rules. |

`WeatherController#index` is **unchanged** — the view receives the same `@future_weather` array of `WeatherDay` and asks for `day.segments` directly.

## Edge Cases

- **Segment with fewer than six records** (e.g. forecast horizon ends mid-day): the aggregation methods skip nils and the segment renders with whatever data is available. The hour-detail row shows that many cards. In practice this only affects the last forecast day.
- **All hours in a segment have `icon: nil`**: `dominant_icon` returns `"unknown"`, which is rendered with the existing `weather_unknown_*` asset.
- **All hours have `solar: nil`**: `avg_solar_w_per_m2` returns nil, view renders "— W/m²".
- **All hours are night** (Nacht segment): view renders "Nacht" instead of a solar number; icon falls back to `weather_*_night.webp` via `dominant_daytime`.
- **Mixed daytime within a non-Nacht segment** (e.g. Abend in summer with sunset partway through): `dominant_daytime` picks the daytime of the most-severe-icon hour, so a thunderstorm at 19:00 still renders with its own day/night context.
- **Empty segment** (no records at all): all numeric methods return nil/0, `all_night?` is false, dominant icon is "unknown". The tile renders but with `—` placeholders. This shouldn't happen for "Nächste Tage" in practice.

## Testing

Unit tests:

- `WeatherSegmentTest`:
  - severity ranking: a single thunderstorm record beats five clear ones.
  - tie within same severity: stable order, earliest hour wins.
  - `temp_min` / `temp_max` ignore nils.
  - `precip_sum` treats nil as 0.
  - `avg_solar_w_per_m2` averages over records with solar, ignores nils, returns nil when none.
  - `all_night?` true only when all records (≥1) are night.
  - `dominant_daytime` picks the daytime of the most-severe-icon record.
  - empty segment: returns nil/0/false/"unknown" appropriately.
- `WeatherDayTest`:
  - `segments` returns four `WeatherSegment`s in fixed order with correct labels and hour ranges.
  - Records bucket into the right segment (boundary test: a record at 06:00 lands in Vormittag, not Nacht).

Integration / view:

- Render "Nächste Tage" with a fixture day that has a 14:00 thunderstorm record. Assert the Nachmittag tile uses `weather_thunderstorm_*` and that no other segment does.
- Assert each day-card renders four segment tiles (not eight slot tiles).
- Assert the hour rows are present in the HTML but emitted with the `hidden` attribute (so server output is the collapsed default).

System / browser test (one):

- Visit `/weather`, click the Nachmittag tile of the first future day, assert hour cards become visible. Click again, assert they hide. Click Vormittag, assert Nachmittag hides and Vormittag opens.

The existing `weather_controller_test.rb` continues to assert that the page renders for the pinned 2026-05-04 fixture; update its assertions only as needed for the markup change (e.g. updated CSS class names).

## Out of Scope / Future

- Severity-aware aggregation in the "Heute" row (current hourly view doesn't suffer from the original problem).
- A "today" segment view as an alternative compact layout (could be considered later if the page grows).
- Persisting which segment is open per day (URL hash, localStorage) — not asked for, and the cost of a fresh-page collapse is small.
- Keyboard arrow navigation between segments — `<button>` already gives Tab/Enter/Space; left/right arrow chording is a separate UX project.
- Surfacing wind gusts or visibility warnings as part of "notable weather" — current scope is icon + temp + precip + solar.
