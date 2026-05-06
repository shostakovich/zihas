# Design: Autarkie- & Eigenverbrauchsquote

## Overview

Add two energy quality metrics to ZiWoAS:

- **Autarkiequote** (self-sufficiency) = `self_consumed / consumed` — how much of the household's consumption is covered by own production.
- **Eigenverbrauchsquote** (self-consumption) = `self_consumed / produced` — how much of own production is consumed locally rather than fed into the grid.

Both metrics depend on the temporally simultaneous overlap of production and consumption. They are surfaced live on the dashboard ("today") and aggregated over the selected range on the reports page (with a per-day trend chart).

## Goals

- Show Autarkie- & Eigenverbrauchsquote as live tiles on the dashboard for today.
- Show both metrics as range-aggregated tiles on the reports page.
- Show a per-day trend chart of both ratios on the reports page for the selected range.
- Compute self-consumption precisely once per day during nightly aggregation, store it, and read from storage afterwards.
- Migrate the existing reports tiles for Ertrag / Verbrauch / Bilanz / Ø-Werte to the same per-day summary table for consistency with the new ratios.

## Non-goals

- No intraday chart of the ratios on the dashboard.
- No grid-feed-in measurement (the system has no dedicated feed-in meter — self-consumption is derived from simultaneity of producer and consumer plug power).
- No threshold/blanking when the denominator is small (0% / 100% extremes are shown as-is).
- No backfill for days where `samples_5min` no longer exists; those days remain blank in the UI.

## Definitions

For a given period (a 5-min bucket, a day, or an arbitrary range):

```
produced_w(t)       = Σ avg_power_w over all producer plugs at time t
consumed_w(t)       = Σ avg_power_w over all consumer plugs at time t
self_consumed_w(t)  = min(produced_w(t), consumed_w(t))

self_consumed_wh    = ∫ self_consumed_w(t) dt
autarky_ratio       = self_consumed_wh / consumed_wh        (0 if consumed_wh == 0)
self_consumption_ratio = self_consumed_wh / produced_wh     (0 if produced_wh == 0)
```

The integration is approximated at 5-minute resolution. Each `samples_5min` bucket already provides per-plug `avg_power_w`; per bucket we sum across plugs by role, take the min, and integrate over the bucket's 300 s. The error vs. sample-precise step-function integration is below ~1% on residential PV daily totals and is not worth the implementation cost.

## Data Model

New table `daily_energy_summary`:

| Column             | Type    | Notes                                                  |
|--------------------|---------|--------------------------------------------------------|
| `date`             | TEXT PK | `YYYY-MM-DD`, local-time date (matches `daily_totals`) |
| `produced_wh`      | REAL    | Σ producer energy for the day                          |
| `consumed_wh`      | REAL    | Σ consumer energy for the day                          |
| `self_consumed_wh` | REAL    | Self-consumed energy for the day                       |

One row per day. The existing `daily_totals` (per-plug) and `samples_5min` (per-plug) tables are unchanged.

## Computation

A single computation path serves both nightly aggregation and the one-off backfill: read `samples_5min` rows for the day, fold across plugs by role, integrate.

Pseudocode:

```ruby
rows = Sample5min.where(bucket_ts: start_ts..(end_ts - 1)).to_a
plug_role = plugs.index_by(&:id).transform_values(&:role)
buckets = rows.group_by(&:bucket_ts)

produced_wh = 0.0
consumed_wh = 0.0
self_consumed_wh = 0.0

buckets.each_value do |bucket_rows|
  prod_w = bucket_rows.select { |r| plug_role[r.plug_id] == :producer }.sum(&:avg_power_w)
  cons_w = bucket_rows.select { |r| plug_role[r.plug_id] == :consumer }.sum(&:avg_power_w)
  produced_wh      += prod_w * (300.0 / 3600.0)
  consumed_wh      += cons_w * (300.0 / 3600.0)
  self_consumed_wh += [prod_w, cons_w].min * (300.0 / 3600.0)
end
```

This logic lives in a small dedicated class (e.g. `DailyEnergySummaryBuilder`) so it can be unit-tested independently of the `Aggregator` and the migration.

### Aggregator hook

`Aggregator#aggregate_day(date_s)` calls the builder after the existing `samples_5min` and `daily_totals` INSERTs are committed, and writes the result to `daily_energy_summary`. It is idempotent: like the other aggregates, the row for the day is `DELETE`d at the start of the transaction and re-inserted.

### Backfill migration

A one-shot migration iterates over distinct dates in `daily_totals.date` and runs the same builder. `samples_5min` is currently retained indefinitely (only the raw `samples` table is purged), so in practice every aggregated day should produce a summary row. The migration tolerates and silently skips any day for which no `samples_5min` rows are found, which keeps it robust against future retention changes. Days with no producer or no consumer rows still produce a row, possibly with zero values.

## Live Dashboard ("Heute")

`EnergySummary` is extended with `self_consumed_wh`. To stay consistent with the historical computation, today's value is computed by bucketing today's `samples` rows into ad-hoc 5-min buckets (sum/avg per plug per bucket), then applying the same fold across plugs by role. This is done in-process without persisting anything.

The existing `/api/today_summary` endpoint gains:

- `self_consumed_wh`
- `autarky_ratio`
- `self_consumption_ratio`

`app/views/dashboard/index.html.erb` gets two new tiles next to the existing today-tiles:

- "Autarkie heute" — percent
- "Eigenverbrauch heute" — percent

The dashboard Stimulus controller (`dashboard_controller.js`) reads the new fields from the polling response and updates the tiles. No threshold or blanking — denominator-zero shows `0 %`.

## Reports

`EnergyReport` is updated to read per-day production / consumption / self-consumption from `daily_energy_summary` instead of folding `daily_totals` per-plug-per-day. Per-plug data (rankings, the per-consumer daily series, the detail chart) continues to use `daily_totals` and `samples_5min`.

### Summary tiles

Existing tiles (Ertrag, Verbrauch, Bilanz, Gespart, Ø Ertrag/Tag, Ø Verbrauch/Tag) are sourced from the new table. Two new tiles are added:

- "Autarkie" — `self_consumed_kwh / consumed_kwh` over the whole range (not the mean of daily ratios)
- "Eigenverbrauch" — `self_consumed_kwh / produced_kwh` over the whole range

Position: after Bilanz, before the Ø tiles.

### Trend chart

A new chart is added showing per-day Autarkie % and Eigenverbrauch % over the selected range. Two lines, y-axis fixed 0–100 %. Position: after the existing Ertrag/Verbrauch energy chart, before the Leistung detail chart. Section label: "Autarkie & Eigenverbrauchsquote".

The chart payload structure (`@report.chart_payload[:daily]`) gains a `ratios` field:

```ruby
ratios: [
  { date: "2026-05-06", autarky_pct: 64.2, self_consumption_pct: 81.7 },
  ...
]
```

Days for which no `daily_energy_summary` row exists are emitted as `null` for both ratios — Chart.js renders these as gaps.

### Range aggregation behaviour

The summary-tile ratios sum `self_consumed_wh` / `consumed_wh` / `produced_wh` only over the days with a `daily_energy_summary` row. Days without a row are excluded from the sums silently (no UI warning). This matches the chart's "gap" treatment and keeps the implementation trivial.

## Error Handling And Edge Cases

- **No producer or no consumer plugs in the bucket:** the missing-side sum is 0, `min(0, x) = 0`, self-consumption is 0. No special-case code.
- **Denominator zero in a ratio:** show 0 % (no `—`, no blanking).
- **Day with no `samples_5min`:** no row is written; chart shows a gap; range tiles exclude the day.
- **Aggregator re-run for an already-aggregated day:** idempotent via DELETE+INSERT inside the existing transaction.
- **Live "today" before any samples have arrived:** all values are 0; ratios are 0 %.

## Testing

Unit tests:

- `DailyEnergySummaryBuilder`: producer-only, consumer-only, producer < consumer, producer > consumer, producer == consumer, no rows, multi-bucket day, multiple plugs per role.
- `Aggregator#aggregate_day`: writes the expected `daily_energy_summary` row; idempotent (running twice yields one row with the same values); existing `daily_totals` and `samples_5min` outputs unchanged.
- Backfill migration: existing days produce rows; days without `samples_5min` are skipped; running twice is safe.
- `EnergyReport`: new summary fields; `chart_payload[:daily][:ratios]` shape; range with a gap day produces `null` entries and excludes that day from the range tiles; existing tiles (Ertrag, Verbrauch, Bilanz, etc.) read from `daily_energy_summary` and produce the same values as before for fully-covered ranges.
- `EnergySummary#compute_today`: returns `self_consumed_wh` matching what the aggregator would produce given the same samples.

Integration:

- `/api/today_summary` JSON includes `self_consumed_wh`, `autarky_ratio`, `self_consumption_ratio`.
- `/reports` renders the two new tiles and the trend chart placeholder; chart payload contains the `ratios` array.

## Out of Scope / Future

- Sample-precise step-function integration over raw samples (current 5-min resolution is sufficient).
- Intraday chart of ratios on the dashboard.
- Per-plug autarky breakdown.
- Grid feed-in metering.
