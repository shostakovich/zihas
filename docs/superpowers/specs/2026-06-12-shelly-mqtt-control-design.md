# Shelly Plug Control via MQTT — Design

**Status:** approved (brainstorm)
**Date:** 2026-06-12
**Scope:** Switch Shelly plugs on/off from a new "Schalten" tab (manual toggles) and via DB-backed time windows (schedules). Shelly only in this iteration; FRITZ!DECT and Govee lamps (brightness/color temperature) are explicitly out of scope. Govee will be integrated later through the driver dispatch point in `PlugCommander`.

## Goal

Until now ziwoas only *reads* from the plugs (`MqttSubscriber` on `<prefix>/+/status/switch:0`). This feature adds the write direction:

- A new **"Schalten" tab** with one row per switchable plug: toggle, live wattage, state + source ("an seit 18:00 (Zeitplan)"), expandable time windows.
- **Time windows** ("Zeitfenster"): from–to with weekday selection, managed in the UI, stored in the DB.
- **Edge-triggered semantics, manual wins:** schedule commands fire only at window edges (start → on, end → off). Between edges the user can switch freely; the schedule never reverts a manual change.

## Decisions (from brainstorm)

| Topic | Decision |
|---|---|
| Triggers | Schedules + separate tab with toggles (no automations, no external API) |
| Devices | Only plugs marked `switchable: true` in `ziwoas.yml`; Shelly only |
| Schedule storage | DB, managed in the UI |
| Rule model | Time windows (from–to, weekdays), arbitrarily many per plug |
| Manual vs. schedule | Manual wins; commands only at window edges |
| Missed edges | Caught up via watermark; skipped if a manual command came after the edge time |
| Architecture | Approach A: Solid Queue tick job + direct MQTT publish from Rails (short-lived connections); collector stays read-only |
| UI layout | Variant C: compact expandable list, inline editor (no modal) |

## Architecture

```
Browser ──POST /plugs/:id/switch──▶ PlugSwitchesController ─┐
                                                            ├─▶ PlugCommander ──MQTT publish──▶ Shelly
recurring.yml ──every minute──▶ ScheduleTickJob ────────────┘        │
                                                                     └─▶ switch_commands (log)

Shelly ──status/switch:0──▶ MqttSubscriber ──▶ plug_states (upsert on output change)
                                          └──▶ ActionCable "dashboard" broadcast ──▶ tab updates live
```

The existing collector process (`bin/ziwoas_collector`) remains untouched except for the `MqttSubscriber` extension (read `output`). All command publishing happens from the Rails side (controller request or Solid Queue worker) over short-lived MQTT connections — on the local broker this costs milliseconds.

## Config

`ziwoas.yml` plugs gain an optional flag, default `false`:

```yaml
plugs:
  - id: stehlampe
    name: Stehlampe
    role: consumer
    switchable: true
```

`ConfigLoader` passes `switchable` through to the plug struct. Only switchable plugs appear in the tab and can have windows. Producer plugs (BKW) and unmarked consumers cannot be switched.

## Data model (SQLite)

**`switch_windows`** — one row per time window:

| Column | Type | Notes |
|---|---|---|
| `plug_id` | string | references the config plug id |
| `on_at` | integer | minutes since midnight (0–1439) |
| `off_at` | integer | minutes since midnight; `on_at > off_at` ⇒ window crosses midnight |
| `days` | json | ISO weekdays of the **start edge**, e.g. `[1,2,3,4,5]` |
| `enabled` | boolean | pause without deleting |

Validation: `on_at != off_at`, at least one weekday, values within 0–1439. All evaluation happens in the configured timezone (`Europe/Berlin`).

**`switch_commands`** — log of every executed command:

| Column | Type | Notes |
|---|---|---|
| `plug_id` | string | |
| `action` | string | `on` / `off` |
| `source` | string | `manual` / `schedule` |
| `created_at` | datetime | |

Written only **after** a successful MQTT publish. Serves the UI ("an seit … (Zeitplan/manuell)") and the manual-wins check during catch-up.

**`plug_states`** — last known actual state per plug:

| Column | Type | Notes |
|---|---|---|
| `plug_id` | string | unique |
| `output` | boolean | |
| `updated_at` | datetime | |

Upserted by `MqttSubscriber` only when `output` changes (not on every status message). Used for initial tab render and offline detection.

**`scheduler_states`** — single row holding `last_tick_at` (the watermark).

## Components

### PlugCommander (`app/models/plug_commander.rb`)

The single choke point for all switch commands:

```ruby
PlugCommander.switch(plug, :on, source: :manual)
```

1. Dispatches on `plug.driver` — this iteration only the Shelly driver exists; other drivers raise a clear error. The dispatch is the future docking point for Govee (whose brightness/color capabilities will get their own design then).
2. Shelly driver: short-lived MQTT connection, publishes `on`/`off` to `<topic_prefix>/<plug_id>/command/switch:0` (Shelly Gen2 command topic).
3. On success, writes the `switch_commands` row. A failed publish writes nothing and raises.

### PlugSwitchesController

`POST /plugs/:id/switch` with explicit `state=on|off` — deliberately not "toggle", so a stale UI cannot race into the wrong state. Checks the plug exists in config and is `switchable` (else 404/422), calls `PlugCommander`, responds with a Turbo Stream. The toggle flips optimistically; the authoritative confirmation arrives seconds later via the Shelly status message → `MqttSubscriber` → `plug_states` + ActionCable broadcast. On publish failure the Turbo Stream shows an error at the toggle instead.

### Edge computation PORO

A pure, I/O-free object: given enabled windows and a time interval `(from, to]`, returns the edge events (plug, action, edge time) within it, honoring weekdays, midnight-crossing windows, and the configured timezone. DST: window times are materialized per local day; Rails shifts nonexistent local times (spring-forward) — good enough for lamps.

### ScheduleTickJob

Runs every minute via the existing `config/recurring.yml`. Per tick:

1. Read watermark (`scheduler_states.last_tick_at`); on the very first run, set it to now and stop (no unbounded replay).
2. Compute edges in `(watermark, now]` via the edge PORO.
3. **Collapse to the latest edge per plug** — after downtime there is at most one command per plug, never an on/off/on burst. This also makes a replay cap unnecessary.
4. **Manual-wins check:** drop an edge if a `switch_commands` row with `source: manual` for that plug exists with `created_at` after the edge time.
5. Execute remaining edges via `PlugCommander` (`source: :schedule`).
6. Advance the watermark to now **only if all publishes succeeded**; otherwise it stays and the next tick retries (repeated on/off is idempotent on the device).

Deliberate edge case: creating a window while already inside it does **not** fire the past start edge — the schedule takes over at the next real edge. The toggle sits right next to the editor if the user wants the lamp on immediately.

### MqttSubscriber extension

Additionally parse `output` from the `switch:0` status payload. When it differs from the stored value, upsert `plug_states` and include the output state in the existing ActionCable broadcast so the tab updates live.

## UI — "Schalten" tab (layout variant C)

New nav entry "Schalten" next to Dashboard/Berichte/Wetter/Sensoren. Existing visual language: light cards, amber accent (`--accent: #f59f00`), green/grey toggles (`--online`/`--offline`).

- **One card per switchable plug**, collapsed by default: toggle (left), name + live wattage, status line ("an seit 18:00 (Zeitplan) · nächste Schaltung: 23:00 → aus" — derived from `plug_states`, `switch_commands`, and the next computed edge), chevron to expand.
- **Expanded:** the plug's windows as amber pills ("Mo–Fr · 18:00–23:00") with pause (⏸ ⇒ `enabled: false`, shown struck-through), edit, and delete actions; plus "+ Zeitfenster".
- **Inline editor** (no modal): two time inputs, "bis" between them, seven weekday pills (Mo–So), save/cancel. Midnight-crossing windows are entered naturally as e.g. 22:00–06:00. Hint text explains this.
- **Offline plugs** (no status for > 5 min): greyed out, toggle disabled, "keine Statusmeldung seit X min".
- Live updates over the existing ActionCable "dashboard" channel.

Mockups from the brainstorm session: `.superpowers/brainstorm/585152-1781243714/content/` (`tab-layout.html`, `tab-detail.html`).

## Error handling

- **Broker down, manual switch:** controller catches, Turbo Stream shows an error at the toggle, no `switch_commands` row.
- **Broker down, tick:** watermark does not advance; next tick retries the same edges.
- **Offline plug:** UI disables the toggle; the scheduler still publishes (a command to an absent device fizzles harmlessly).
- **Window for a plug no longer in config / no longer switchable:** ignored by tick and tab rendering; UI lists it as orphaned with a delete option.

## Testing (Minitest, matching existing style)

- **Edge PORO:** weekdays, midnight crossing, collapse-to-latest, DST transitions, empty interval — pure unit tests, no mocks.
- **ScheduleTickJob:** first-run watermark init, normal edge firing, manual-wins skip, watermark frozen on publish failure (commander mocked).
- **PlugCommander:** driver dispatch, unknown driver raises, log row only after successful publish (MQTT client mocked).
- **PlugSwitchesController:** unknown/non-switchable plug → 404/422, success → Turbo Stream, broker failure → error response.
- **MqttSubscriber:** `output` change → upsert + broadcast; unchanged `output` → no DB write.

## Out of scope

- FRITZ!DECT switching (AHA command via the Fritz bridge)
- Govee lamps (on/off, brightness, color temperature — own design later)
- Automations based on measurements (e.g. switch on at solar surplus)
- External HTTP API for third-party systems
- State enforcement / reconciler semantics
