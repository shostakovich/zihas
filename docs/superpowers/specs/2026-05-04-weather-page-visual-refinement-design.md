# Weather Page Visual Refinement Design

## Goal

Refine the visual presentation of `/weather` so that solar irradiance reads
as a real piece of information rather than incidental rows of `0 W/m²`, day
forecasts read like forecasts instead of data tables, and night hours are no
longer rendered as zero-watt slots.

This design only refines the page layout. It does not introduce new data,
new configuration, PV yield calculations, or kWh values. The Bright-Sky
fields, jobs, model, and routing established by
`2026-05-04-weather-area-design.md` remain unchanged.

## Out of Scope

- PV yield calculation (W/m² → kWh) and any related config such as
  `weather.pv_kwp`.
- Dashboard changes.
- Reports integration.
- New columns on `weather_records`.
- New jobs or job schedule changes.

## Section: Current Weather (`weather-current`)

The current weather card keeps its three-part layout: weather icon, primary
temperature/condition column, and a four-cell facts column showing
`Luft %`, `Wolken %`, `Regen mm`, and `hPa`.

Add a dedicated solar row below the facts area, separated by a dashed
top border, formatted as:

```
☀ Solar   320 W/m²
```

The label uses an amber accent color and small uppercase styling. The value
uses the regular text color and a slightly larger weight so the W/m² number
reads as the headline of that row.

Solar row content rules (same precedence used in every section):

- `daytime == "night"`: render `☀ Solar   Nacht`, regardless of any numeric
  solar value.
- `daytime == "day"` and `solar` present: render
  `☀ Solar   <integer> W/m²`.
- `daytime == "day"` and `solar` missing: render `☀ Solar   —`.

## Section: Today (`weather-hour-row`)

The hourly row stays horizontally scrollable. Each card displays, top to
bottom:

1. Top row: time on the left (`13:00`), precipitation on the right —
   `<value> mm` if `precipitation` is present, otherwise
   `<value>%` from `precipitation_probability`, otherwise omitted.
2. Weather icon (existing asset).
3. Temperature, large and bold (`18°`).
4. **Solar row, prominent.**
5. Wind row, small and muted (`💨 11 km/h`).

Solar row content rules:

- `daytime == "night"`: render `☾ Nacht` in muted color, regardless of any
  numeric solar value present in the record.
- `daytime == "day"` and `solar` present: render `☀ <integer> W/m²` in the
  amber accent color.
- `daytime == "day"` and `solar` missing: render `Wolken <cloud_cover>%`
  (existing fallback).

## Section: Next Days (`weather-days`)

Each forecast day is rendered as one card with a two-part header followed
by an eight-column three-hour grid.

### Header

Left side, stacked:

- Weekday name in title weight (`Dienstag`).
- Daily summary line in muted color: `<temp_min> – <temp_max> °C · Regen <precip_sum> mm`.

Right side:

- `☀ Spitze <solar_peak> W/m²` in the amber accent color. Hidden if
  `solar_peak` is `nil`.

### Three-hour grid

Eight columns for hours `00, 03, 06, 09, 12, 15, 18, 21`. Each slot shows:

- Hour label (`12`).
- Weather icon.
- Temperature (`17°`).
- Solar value: `<integer> W/m²` during the day, `Nacht` (muted, no number)
  when `daytime == "night"`. The night text replaces the existing
  `Wolken <cloud_cover>%` fallback in this position only when the slot is at
  night; daytime fallbacks behave as in the Today section.

A slot is selected when its `timestamp.hour` is divisible by three (existing
behavior). Slots that the API does not return for those hours are simply
omitted; the grid keeps eight column tracks and renders empty cells in
their place.

## Day-Level Aggregation

`WeatherController#index` computes one aggregate per future date from the
forecast records that are already grouped by date:

- `temp_min`: minimum of `temperature` across the day's records.
- `temp_max`: maximum of `temperature` across the day's records.
- `precip_sum`: sum of `precipitation` across the day's records, treating
  `nil` as `0`. Rendered with one decimal.
- `solar_peak`: maximum of `solar` across the day's records. `nil` if every
  record's `solar` is `nil`.

The controller exposes these aggregates so the view can read them per date
without recomputing from records. Concretely, the existing future-weather
collection becomes a list of per-day structures, each carrying the date,
the records, and the four aggregates above.

## Night Detection

The view treats `record.daytime == "night"` as the single criterion for
night rendering. No additional hour-based logic is added in views or
helpers. `WeatherRecord#daytime` already exists and is set during record
creation.

## CSS

Existing `.weather-*` classes in `app/assets/stylesheets/application.css`
are extended in place rather than duplicated. Specifically:

- A new amber accent color is added as a CSS variable next to existing
  theme variables, used for solar labels and values.
- `.weather-current` gains a sub-rule for the solar row with a dashed
  `border-top` separator.
- `.weather-hour-card` gains a `.weather-hour-solar` rule for the
  prominent solar line and a muted variant for `Nacht`.
- `.weather-day-card` and `.weather-day-slot` are restructured to support
  the new header (weekday, summary, peak) and the three-hour grid layout.

The page must remain readable at narrow viewport widths. The Today row
keeps horizontal scroll. The day grid wraps the eight columns into a
two-row 4×2 layout below a configured breakpoint instead of overflowing.

## Tests

Update existing controller and view specs; add new assertions where
required. No new test files.

### Controller spec

- The future-weather payload exposes `temp_min`, `temp_max`, `precip_sum`,
  and `solar_peak` for each grouped day, computed as defined above.
- A day whose forecast records all have `solar == nil` produces
  `solar_peak == nil`.

### View spec for `/weather`

- The current-weather card renders the solar row.
- The current-weather card renders `Nacht` in place of a W/m² value when
  `daytime == "night"`, even when `solar` happens to be present.
- An hourly card with `daytime == "night"` renders `Nacht` and not a
  W/m² value, even when `solar` happens to be present.
- A day card renders the weekday name, the `temp_min – temp_max °C` and
  `Regen <precip_sum> mm` summary, and the `Spitze <solar_peak> W/m²`
  badge.
- A day card whose `solar_peak` is `nil` does not render the peak badge.
- The day grid renders one slot per three-hour boundary.

The existing empty-state test (no current weather, no records) continues
to render the empty state and is not affected.
