# Solakon PV Overview And Control Page Design

**Datum:** 2026-06-20
**Status:** Abgenommen (Design), bereit für Spec-Review durch User

## Goal

Build a dedicated Solakon ONE page for PV overview, storage details, Solakon-side history, and direct control of the Solakon EPS output and zero-export runtime control.

The page should feel like the existing Ziwoas dashboard and reports: compact, friendly, mobile-first, and technically useful without exposing Modbus register names or implementation details in the main UI.

## Decisions

- Use a single continuous page, not tabs.
- Reuse the existing dashboard live energy-flow visual pattern instead of designing a new flow diagram.
- Show only the currently connected PV strings: **Panel 1** and **Panel 2**. Do not show empty Panel 3/4 cards.
- Use user-facing labels: **Außensteckdose**, **Auto-Regelung**, **Batteriegesundheit**, **PV**, **Akku**, **Netz**.
- Do not show Modbus register addresses, bit names, or raw protocol language in the main UI.
- Do not label SOH as `SOH` in the UI. Show it as **Batteriegesundheit**.
- Do not show "Ladezyklen" as a real protocol value. The protocol does not provide it.
- Use one combined Solakon graph for PV, battery, and grid behavior.
- Replace the dashboard hero battery icon with the new plush battery character. The battery icon inside the existing energy-flow SVG may also be replaced if it stays simple and clean.

## Page Structure

The page is a single scrollable dashboard:

1. Live energy flow.
2. Control cards.
3. Panel cards.
4. Storage cards.
5. Solakon graph and short balance.
6. Status and alarms.

The page should be reachable from the main navigation with a short label such as `PV` or `Solakon`. The final nav label can be chosen during implementation to fit the existing mobile bottom nav.

## Live Energy Flow

The page reuses the existing dashboard energy-flow design and behavior as much as practical. This keeps the Solakon page familiar and avoids a second visual language for the same concept.

The flow should show:

- PV generation.
- Wohnung consumption.
- Battery state of charge and battery power.
- Grid import/export.

Labels should stay compact. The live-flow section is the page's orientation layer, not the place for every diagnostic value.

If there is no fresh Solakon reading, Solakon-dependent values show unavailable placeholders and active flow animations stop, consistent with current dashboard behavior.

## Controls

### Außensteckdose

The outside socket is the Solakon EPS output. The UI calls it **Außensteckdose**.

The card shows:

- Current state: on/off.
- Live voltage when available.
- Live power when available.
- A toggle for switching the output.

The UI does not mention EPS register numbers. A secondary detail label may say `Notstrom-Ausgang` if helpful, but the main label remains `Außensteckdose`.

Switching is performed directly through `SolakonClient`, not through `PlugCommander` or the Shelly plug-switching path.

### Auto-Regelung

The zero-export runtime control is shown as **Auto-Regelung**.

The card shows:

- Whether runtime control is active or paused.
- Helper text such as `hält Einspeisung nahe 0 W`.
- A toggle that pauses or resumes runtime control only when config permits control.

The config remains the master switch. If `solakon.control_enabled` is false, the toggle is visible but grey, disabled, and not clickable. The status text should say something like `in Konfiguration deaktiviert`.

When config permits control, the toggle changes a persistent runtime state. `ZeroExportTickJob` must check both:

- The config master flag.
- The persistent runtime active/paused state.

## Panels

The panels section shows only connected panels.

For the first version, show:

- **Panel 1**
- **Panel 2**

Each panel card shows:

- Power in W.
- Voltage in V.
- Current in A.

Panel 3 and Panel 4 are not shown while they are unused. The implementation can still store/read additional string values in the slow snapshot model so future panels can appear without redesign.

## Storage

The storage section uses user-facing labels and concise cards.

Show:

- Ladestand.
- Batteriegesundheit.
- Aktuelle Batterieleistung.
- Batteriespannung.
- Batteriestrom.
- Speichertemperatur.
- Available capacity values when reliable: remaining energy, full-charge capacity, and/or design energy.

Use `Batteriegesundheit` for protocol SOH. Do not show `SOH` as the primary label.

Do not claim protocol-backed charge cycles. If a future implementation estimates equivalent full cycles from energy throughput, it must be clearly labeled as an estimate and should not be part of the first version's primary cards.

## Graphs

The graph area follows existing Ziwoas report patterns:

- `chart-card` and `chart-frame` layout.
- Chart.js for real implementation.
- Existing report-style time controls.
- Progressbar-style short balance rows similar to the report ranking bars.

### Time Range

Use three range chips:

- `Letzte 24 h`
- `Letzte 7 Tage`
- `Letzte 30 Tage`

The selected range applies to both the graph and the short balance.

### One Combined Solakon Graph

Use one combined graph with short labels:

- `PV`
- `Akku`
- `Netz`
- `0 W`

PV generation is shown as its own positive line/filled line.

Battery and grid are signed lines around the zero line:

- **Akku:** `+` charges, `-` discharges.
- **Netz:** `+` means grid import, `-` means grid export.

The chart legend stays short. The sign explanation appears below the chart, not in long legend labels.

### Short Balance

Show a compact balance list with progressbars:

- PV-Erzeugung.
- Akku geladen.
- Akku entladen.
- Netzbezug.
- Netzeinspeisung.
- Ø Netzleistung.

These are Solakon-side metrics, not a duplicate of the existing whole-home reports.

## Status And Alarms

The status section is compact by default.

Normal state examples:

- `Alles ruhig`.
- `Keine Batterie-Warnung`.
- `Wechselrichtertemperatur 34 °C`.
- `Außensteckdose bereit`.

Warnings and errors should use short, human-readable messages in the main view. Raw status codes, alarm groups, and BMS fault details can live in an expandable details area.

The UI should not lead with register names, bit names, or protocol table labels. Those details belong in tests, code comments where needed, and the protocol documentation.

## Plush Battery Assets

Create a new plush-style battery character family that matches the existing Ziwoas asset style.

Required states:

- Normal: friendly and calm.
- Charging: active, sunny, energized.
- Low charge: sleepy or tired.
- Overtemperature: clearly sweating.
- Cold: visibly cold or shivering.
- Fault/alarm: confused or distressed, but not scary.

The new battery character replaces the dashboard hero battery icon. Replacing the battery inside the dashboard energy-flow SVG is optional and should be done only if it is straightforward and visually clean.

Generated image assets should be stored as project assets during implementation, not left in temporary image-generation output folders.

## Data Collection

Keep the existing fast `SolakonReading` tick lean. Extend it only with fast live values needed by the page and existing control path:

- Battery voltage.
- Battery current.
- Inverter internal temperature.
- Status and alarm bits.

Add a new slow Solakon snapshot job and table for values that are slower-moving or graph/detail oriented:

- Storage detail values: battery voltage/current, capacity values, Batteriegesundheit, temperatures.
- Per-panel values: PV1/PV2 power, voltage, current; keep schema able to support PV3/PV4 later.
- Energy counters from the protocol energy table.
- Status, alarm, and BMS fault snapshots.
- EPS status and live EPS voltage/power when useful for the page.

The slow snapshot cadence should be about every 10 minutes. This creates a future-friendly basis for the 7-day and 30-day graph ranges.

The fast tick remains appropriate for live cards, current flow, and control decisions. The slow snapshot model powers historical detail and summaries.

## Architecture

Likely implementation units:

- `SolakonClient`: add read/write helpers for EPS output and additional read helpers for snapshot values.
- `SolakonReading`: keep as fast live reading model.
- New slow snapshot model, for example `SolakonSnapshot`, for slower details and counters.
- New recurring snapshot job, for example `SolakonSnapshotJob`.
- Persistent runtime control state for Auto-Regelung pause/resume.
- New controller/page for the PV/Solakon overview.
- New JSON endpoint(s) for graph range data if the page uses Stimulus/Chart.js similarly to existing reports and sensor charts.
- Stimulus controller for the Solakon page graph and toggles, following existing Chart.js controller patterns.

Do not route EPS switching through `PlugCommander`, because it is not a Shelly plug switch.

## Error Handling

If Solakon is unavailable:

- The page loads.
- Live values show placeholders or stale/unavailable status.
- Controls are disabled or report a clear failure state.
- The graph still shows historical data if available.

If EPS switching fails:

- The toggle returns to the last confirmed state.
- Show a concise error message near the outside-socket card.
- Log the underlying error.

If Auto-Regelung is config-disabled:

- The toggle is grey and disabled.
- Runtime state cannot enable control beyond the config master switch.

If slow snapshot values are missing:

- Omit unavailable details or show placeholders.
- Do not show Panel 3/4 placeholders just because the protocol supports them.

## Testing

Add focused tests for:

- User-facing controller/page response.
- EPS read/write behavior in `SolakonClient`, including verified on/off values.
- Auto-Regelung runtime state and `ZeroExportTickJob` gating.
- Config-disabled Auto-Regelung toggle state.
- Slow snapshot persistence and value scaling.
- Graph API/range aggregation for 24 h, 7 days, and 30 days.
- UI behavior for missing Solakon data, disabled controls, and active controls.
- Dashboard hero battery asset replacement.

Manual verification should include:

- Read-only probe against the live inverter.
- EPS status read, switch off/on, and status re-read.
- Auto-Regelung active, paused, and config-disabled states.
- Page rendering on desktop and mobile.
- Graph range switching.

## Out Of Scope

- A full replacement of existing dashboard and report pages.
- Showing unused PV3/PV4 cards before panels are connected.
- True charge-cycle reporting from protocol data.
- New grid-meter hardware integration.
- Detailed protocol/register UI in the main page.
