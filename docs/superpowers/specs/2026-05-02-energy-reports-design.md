# Design: Rails-first Energy Reports

## Overview

Add a new, navigation-accessible reports area for energy retrospectives. The first report focuses on detailed production and consumption over preset and custom date ranges:

- Last 7 days
- Last 30 days
- Custom start and end date range

The feature should be designed as a growing home for future sensor reports, not as another section appended to the live dashboard.

## Goals

- Provide detailed retrospective views for energy production and consumption.
- Show both total values and per-sensor/per-plug contributions.
- Support mobile devices as a first-class layout target.
- Use Rails-first rendering for the report page, with Stimulus only initializing charts and lightweight interactions.
- Establish a pattern that can later inform a Rails-first dashboard migration with Turbo Streams or WebSocket updates.

## Non-goals

- Do not migrate the existing dashboard to Rails-first in this feature.
- Do not add export, PDF, period comparison, weather, tariff, or advanced cost analysis.
- Do not make a new JSON API the primary rendering path for this report.
- Do not hide per-sensor details behind a later-only drilldown; they should be visible in the report.

## Navigation And Page Structure

Add a visible application navigation with at least:

- Dashboard
- Reports

The reports page lives at `/reports` and is handled by `ReportsController#index`.

Desktop layout:

- Global navigation with an active state.
- Date range controls at the top of the report content.
- Summary metrics below the controls.
- Main chart and sensor ranking in a layout that can sit side by side when space allows.
- Drilldown/detail chart below the primary overview.

Mobile layout:

- Compact top navigation instead of a wide sidebar.
- Single-column report flow.
- Date range controls near the top and easy to reach.
- Summary metrics in a compact two-column grid when space allows, falling back cleanly on narrow screens.
- Charts and sensor ranking stacked vertically.

## Date Range Controls

The page should include:

- A preset for "Last 7 days"
- A preset for "Last 30 days"
- A compact date-range picker for custom start and end dates

The selected range is reflected in request parameters so the page can be refreshed, shared, and server-rendered deterministically.

## Data Sources

Use the existing aggregate tables according to the requested range and chart purpose:

- `daily_totals` for period summaries, daily bars, and per-plug totals across multi-day ranges.
- `samples_5min` for fine-grained detail views and short-range drilldowns.

The currently open day may need special handling because `daily_totals` is produced by aggregation for finished days. The implementation plan should decide whether to include partial current-day data from raw or 5-minute samples, or to make the selected preset ranges end at the latest fully aggregated day. The UI must make that behavior explicit.

## Rails-first Data Flow

Do not introduce a new JSON API as the primary data path.

Instead:

- `ReportsController#index` parses and validates date-range parameters.
- A dedicated query/service object, for example `EnergyReport`, calculates report data.
- The Rails view renders summary values and sensor ranking directly as HTML.
- The Rails view embeds chart payloads as JSON in the page, for example via `script type="application/json"` or a focused data attribute.
- A Stimulus controller reads the embedded payload and initializes Chart.js.

Stimulus should not own report calculations. It should handle chart initialization, chart teardown, and small presentation interactions.

## Automatic Resolution

Use automatic resolution rather than making the user choose chart density.

Recommended behavior:

- Short ranges, up to about 2 days: use `samples_5min`.
- Medium ranges, up to about 30 days: show daily overview from `daily_totals`; drilldowns can use `samples_5min` for a selected day.
- Longer custom ranges: use daily data by default.

The exact thresholds can be tuned during implementation, but the intent is clear: detailed when zoomed in, readable and fast when zoomed out.

## First Version Content

Top section:

- Range controls
- Summary cards for production, consumption, and balance
- Optional self-consumption or coverage metric only if it is clearly derivable from existing data

Primary analysis:

- Chart showing production and consumption over the selected range
- Daily bars for 7-day and 30-day ranges
- Automatically selected detail resolution for short ranges

Sensor detail:

- Always-visible per-plug/per-sensor ranking for the selected period
- The ranking should distinguish producer and consumer roles
- Values should be shown in kWh with consistent number formatting

Drilldown:

- A selected day can show a finer detail series from `samples_5min`
- The drilldown should make clear which day or sub-range it represents

## Error Handling And Empty States

- Invalid date parameters should fall back to a safe default, preferably last 7 days.
- Start dates after end dates should be corrected or rejected with a clear page-level message.
- Ranges with no data should render an empty state rather than a broken chart.
- Missing sensor data should not prevent other sensors from rendering.
- Chart payloads should be valid JSON even when series are empty.

## Testing

Backend tests should cover:

- Default range selection.
- Last 7 days and last 30 days.
- Custom date range parsing.
- Invalid range fallback or validation behavior.
- Summary totals split by producer and consumer roles.
- Per-plug ranking.
- Automatic resolution selection.
- Empty-data behavior.

Frontend tests can stay focused:

- Stimulus chart controller initializes Chart.js from embedded JSON.
- Empty payload does not throw.
- Existing dashboard chart behavior is not changed by this feature.

System or integration coverage should verify:

- `/reports` renders.
- Navigation links to Dashboard and Reports.
- Mobile layout remains usable at narrow viewport widths.

## Future Extensions

This reports page should be able to grow into:

- Additional sensor reports.
- Period comparisons.
- Exports.
- Cost and tariff analysis.
- Dashboard migration toward Rails-rendered initial state with Turbo Stream or WebSocket updates.
