# Solakon One Control Algorithm Design

Date: 2026-06-20  
Status: Partly superseded — see note below.

> **Update (2026-06):** The controller was later reduced to **two** states:
> `PROTECTED` and the normal mode (symbol `:normal`, formerly `:pv_priority`).
> The two nighttime special modes — `EVENING_CATCH_UP` and `NIGHT_BASE` — and the
> daytime battery-help cap (`DAY_BATTERY_HELP_W`, 250 W) were removed. The normal
> mode now simply targets the measured household load up to the legal 800 W cap;
> the inverter serves it from PV first and tops up from the battery internally.
> The sections below describing `EVENING_CATCH_UP`, `NIGHT_BASE`, the energy
> budget, the asymmetric smoothing (`RISE_FACTOR`/`FALL_FACTOR`), and the related
> constants (`EVENING_DISCHARGE_LIMIT_W`, `NIGHT_BASE_RESERVE_W`, `BASE_DEADBAND_W`,
> `ConsumptionReader::NIGHT_BASE_DAYS`, `SunWindow`) no longer reflect the code and
> are kept only as a historical record. `PROTECTED` and the thermal/SoC behavior
> are unchanged.

## Background

The Solakon One should harvest PV surplus and later release that energy to improve self-consumption. The controller should not chase every short household load spike. Small grid import or export around 10 W is acceptable. The main goals are: PV directly to the house first, useful battery discharge later, low SoC and thermal protection, and sparse but reliable Modbus writes.

The existing Solakon monitoring path reads inverter state regularly. Control is optional and writes Modbus values only when `control_enabled` is true. This design extends the current zero-export feed-forward controller instead of adding a separate control system.

## Existing Building Blocks

- `ConsumptionReader#current_consumption_w` is the household load input: sum of fresh consumer plug samples.
- `ConsumptionReader#guaranteed_floor_w` remains useful as a conservative fallback load estimate.
- `SolakonClient` reads SoC, PV power, AC active power, and battery power.
- `SolakonClient::REMOTE_TIMEOUT_S` is 150 seconds. Remote control must be rearmed before this watchdog expires.
- `SunCalc.sunrise` and `SunCalc.sunset` provide sunrise and sunset from the configured weather location and timezone.

Algorithm thresholds are **Ruby constants in code**, not config:

- `SolakonReading` owns battery-safety constants: `MIN_SOC_PCT` 10, `RESUME_SOC_PCT` 11, `HOT_TEMP_C` 42.0, `HOT_RESUME_TEMP_C` 41.8, `PV_PRESENT_W` 50, `USABLE_CAPACITY_WH` 1920.
- `ZeroExportController` owns control-tuning constants: `MAX_OUTPUT_W` 800, `DAY_BATTERY_HELP_W` 250, `EVENING_DISCHARGE_LIMIT_W` 800, `HOT_OUTPUT_LIMIT_W` 400, `NORMAL_DEADBAND_W` 50, `BASE_DEADBAND_W` 15, `NIGHT_BASE_RESERVE_W` 5, `RISE_FACTOR` 0.25, `RISE_CAP_W` 50, `FALL_FACTOR` 0.80.
- `ConsumptionReader::NIGHT_BASE_DAYS` is 7.
- `SunWindow::FALLBACK_SUNRISE_HOUR` / `FALLBACK_SUNSET_HOUR` are 6 / 20.

`solakon.yml` keeps only `host`, `port`, `unit_id`, `monitoring_enabled`, `control_enabled`, `stale_after_s`. No algorithm threshold lives in config.

## Prime Directive

PV-to-house has priority over battery discharge. Storing PV in the battery and discharging it later is useful, but direct PV consumption is cheaper and should win whenever possible.

The Solakon active-power setpoint controls total AC output. If the setpoint is below current PV, the surplus can charge the battery internally. If the setpoint is above current PV, the difference may come from the battery. This means one active-power target can express both PV-to-house and battery discharge behavior.

Hard cap:

```text
target_w <= 800 W
```

The 800 W cap always applies because the outside socket / balcony PV limit must not be exceeded.

## State Machine

Use a small state machine for coarse behavior. The state chooses intent; pure functions calculate the target watts.

### PROTECTED

Purpose: avoid intentional battery discharge when SoC is low, and avoid running the inverter hot.

`PROTECTED` covers both low-SoC protection and thermal protection with hysteresis around each entry threshold:

Enter when:

- SoC is at or below 10% (`MIN_SOC_PCT`), or
- battery temperature is at or above 42.0 °C (`HOT_TEMP_C`), or
- control state is unsafe because required sensor data is missing.

Leave when, for a fresh reading:

- SoC is at least 11% (`RESUME_SOC_PCT`) **and**
- battery temperature is at or below 41.8 °C (`HOT_RESUME_TEMP_C`).

Both conditions must hold simultaneously — a battery that has cooled but is still at low SoC stays in `PROTECTED`, and vice versa. If this flaps in practice, require two consecutive fresh readings.

Behavior:

- While SoC has not resumed: do not intentionally request battery discharge. Target is at most PV power, further capped by the thermal ceiling below.
- Once SoC has resumed (so the only reason still in `PROTECTED` is heat): the target **follows actual household load down**, capped at 400 W (`HOT_OUTPUT_LIMIT_W`) — not capped by the daytime `DAY_BATTERY_HELP_W` (250 W) battery-assist limit, which only applies in `PV_PRIORITY`. Lower total AC output means less inverter throughput and less internal heat; the Solakon One splits battery vs. PV internally, so the controller does not need to manage that split. The discharge-current-limit register is not used (see Current Limit Registers).
- While battery temperature is still hot, total AC output is throttled to the 400 W ceiling regardless of SoC state.
- The hard lower SoC boundary is still the inverter minimum SoC setting; the controller is best-effort above that.

### PV_PRIORITY

Default daylight mode and also any time PV is meaningfully present. Battery discharge is allowed, including during the day, but only after PV has covered as much load as possible.

```text
pv_direct_w = min(pv_w, household_load_w)
remaining_load_w = max(0, household_load_w - pv_direct_w)

battery_help_w = min(remaining_load_w, DAY_BATTERY_HELP_W)

raw_target_w = pv_direct_w + battery_help_w
target_w = apply_output_caps(raw_target_w)
```

`PV_PRIORITY` is only reachable once SoC has resumed (otherwise the controller stays in `PROTECTED`), so no separate SoC-based discharge limit is needed here — `DAY_BATTERY_HELP_W` (250 W) is the only battery-assist cap.

Examples:

- PV 100 W, load 386 W: target is 100 W direct plus up to 250 W of battery help, so about 350 W (capped further by `remaining_load_w` if load is smaller).

### EVENING_CATCH_UP

Used after sunset when the battery has more usable energy than expected base load can consume by sunrise. It may discharge more than base load, but must not follow short appliance peaks.

Use asymmetric smoothing:

- Increase target slowly: at most `RISE_FACTOR` (25%) of the gap to the measured load, capped at `RISE_CAP_W` (50 W) per tick.
- Decrease target quickly: `FALL_FACTOR` (80%) of the gap per tick.
- Always clamp the result to the current fresh measured load (export-safe), in addition to the evening discharge limit.

```text
smoothed_load_w = asymmetric_smoothed(household_load_w)
raw_target_w = min(smoothed_load_w, household_load_w, max_evening_discharge_w)
target_w = apply_output_caps(raw_target_w)
```

The `household_load_w` clamp preserves the export-safe property from the original zero-export design. When a large load switches off, the target must fall quickly instead of exporting for the smoothing window.

### NIGHT_BASE

Used once remaining usable battery energy is low enough that the night base load should empty the battery by sunrise.

Base load:

```text
night_base_w = P20 of recent night 5-minute household consumption buckets
base_target_w = max(0, night_base_w - 5 W)
```

Definition:

- Use the last `NIGHT_BASE_DAYS` (7) nights by default.
- A night bucket is between sunset and sunrise, excluding the first hour after sunset and the last hour before sunrise to avoid evening and morning activity.
- If there is not enough night data, fall back to `guaranteed_floor_w`.

P20 is chosen because the house has stable always-on server/router load. It stays near the real base load while ignoring spikes and avoiding fragile absolute minima.

Switch from `EVENING_CATCH_UP` to `NIGHT_BASE` when:

```text
usable_wh <= night_base_w * hours_until_sunrise
```

Behavior:

- Use the calm base target.
- Let the grid cover spikes.
- Avoid frequent writes except for the remote-control heartbeat.

## Energy Budget

```text
usable_wh = max(0, soc_pct - 10) / 100 * battery_capacity_wh
base_need_wh = night_base_w * hours_until_sunrise
```

If `usable_wh > base_need_wh`, use `EVENING_CATCH_UP` after sunset.

If `usable_wh <= base_need_wh`, use `NIGHT_BASE`.

This intentionally aims to make room for the next PV day. Without a PV forecast this is a heuristic. Weather/solar forecast can later scale the target more conservatively on expected poor PV days, but v1 should keep the rule simple and explicit.

`hours_until_sunrise` is measured against `SunWindow`'s **next upcoming sunrise** — today's if we are before it, tomorrow's if we are already past it — so the budget never collapses to zero late at night. When no weather location is configured, `SunWindow` falls back to fixed 06:00/20:00 sunrise/sunset (`FALLBACK_SUNRISE_HOUR` / `FALLBACK_SUNSET_HOUR`), which keeps the controller behaving in a `PV_PRIORITY`-like daytime/night split even without real sun data.

## Transitions

```text
any state -> PROTECTED
  when SoC <= 10%, battery_temp >= 42.0 C, or required sensor data is missing

PROTECTED -> PV_PRIORITY
  when SoC >= 11% and battery_temp <= 41.8 C, and (PV is present or it is daytime)

PROTECTED -> NIGHT_BASE
  when SoC >= 11%, battery_temp <= 41.8 C, it is night, and usable_wh <= base_need_wh

PV_PRIORITY -> EVENING_CATCH_UP
  after sunset when usable_wh > base_need_wh

PV_PRIORITY -> NIGHT_BASE
  after sunset when usable_wh <= base_need_wh

EVENING_CATCH_UP -> NIGHT_BASE
  when usable_wh <= base_need_wh

EVENING_CATCH_UP -> PV_PRIORITY
  at sunrise or when meaningful PV is present

NIGHT_BASE -> PV_PRIORITY
  at sunrise or when meaningful PV is present
```

Use small hysteresis for PV presence and sunrise/sunset boundaries so clouds or minute-level timing do not cause rapid state changes.

## Write Policy

Read regularly. Write only when needed, but keep the remote-control watchdog alive.

Write triggers:

- State changed.
- Target changed beyond deadband.
- Protection requires immediate action.
- Remote control heartbeat is due.
- Remote control was lost or timeout is close to expiry.

Heartbeat:

```text
remote_timeout_s = 150
heartbeat_s = 120
```

Even when the target is unchanged, rearm remote control around every 120 seconds while control is active. This is required because the inverter drops remote control when the watchdog expires.

Deadbands:

- Normal target changes: 50 W.
- Base-load target changes: 15 W.
- Tiny import/export around 10 W: ignore.

Target decreases also respect the deadband unless there is a real protection or export-risk reason. A 10 W export is not enough reason to write.

Wear note: the remote control registers are volatile and are safe to write every tick according to the current client comments. Sparse writes are still useful to reduce unnecessary control churn and avoid chasing load peaks. Persistent registers such as minimum SoC must not be written every tick.

## Failure Handling

A control decision requires fresh Solakon state and household load input.

If the Solakon **read** fails:

- The read happens in `SolakonMonitorJob`, which aborts on a Modbus error and
  does not invoke control. No target is written.
- Because no write re-arms `REG_REMOTE_TIMEOUT`, the inverter's own 150 s
  remote-control watchdog drops remote control autonomously. That hardware
  watchdog is the intended backstop for read outages — the controller does not
  need its own read-failure release path under the production call path.

If household **load** is unavailable (no fresh consumer sample):

- Fall back to `guaranteed_floor_w` (the 24 h minimum, recomputed each tick).
  This is conservative and export-safe, and is never an "old high target", so
  the controller keeps writing the floor rather than releasing control.

If a **write** fails:

- Count consecutive failures (`ZeroExportTickJob#handle_failure`).
- After `MAX_CONSECUTIVE_FAILURES` (3), call `release_control!` so the inverter
  reverts to its own default behavior.

## Temperature

Store battery temperature in `solakon_readings` as `battery_temperature_c`.

Use the BMS maximum temperature register as the protection signal. The Home Assistant integration identifies `bms1_max_temp` as register `37617`, signed 16-bit, scale 10, in Celsius.

Thermal protection is **not** merely a cap layered on top of another state — it is the `PROTECTED` state itself, entered with hysteresis:

- Enter `PROTECTED` when `battery_temperature_c >= 42.0 C` (`HOT_TEMP_C`).
- Leave only when `battery_temperature_c <= 41.8 C` (`HOT_RESUME_TEMP_C`) **and** SoC has resumed.

While in `PROTECTED` for thermal reasons (SoC already resumed), the target **follows actual household load down**, capped by a linear thermal de-rating ceiling that ramps from `HOT_OUTPUT_LIMIT_W` (400 W) at `HOT_TEMP_C` (42 °C) down to 0 W at `CUTOFF_TEMP_C` (48 °C):

```text
ceiling_w = battery_cooled? ? 800 W
                            : (400 W * (48 - temp_c) / (48 - 42)).round.clamp(0, 400)
target_w  = min(household_load_w, ceiling_w)
```

So 42 °C → 400 W, 45 °C → 200 W, 48 °C and above → 0 W (no battery discharge). The de-rating is **independent of SoC**: a full, hot battery is throttled too — the inverter simply curtails PV when there is nowhere for the energy to go, which lets the battery rest and cool. This cap applies to the whole AC target, not only to battery help, and it is **not** limited by the daytime `DAY_BATTERY_HELP_W` (250 W) cap — that cap is specific to `PV_PRIORITY`. Lower total AC output is preferred while hot because it means less inverter throughput and therefore less internal heat. The Solakon One splits battery power vs. PV power internally to meet the active-power setpoint; the controller does not manage that split and does not use the discharge-current-limit register for this purpose (see Current Limit Registers).

## Discharge Limits

`battery_help_w` (the part of the target above PV) is bounded per state, implemented as `ZeroExportController.pv_priority_target` / `protected_target` / etc. rather than one generic formula:

```text
battery_help_w = min(remaining_load_w, mode_discharge_limit_w)
```

- `PV_PRIORITY`: `mode_discharge_limit_w = DAY_BATTERY_HELP_W` (250 W).
- `PROTECTED` (SoC at or below 10%, until resume at 11%): no intentional discharge — target is at most PV power.
- `PROTECTED` (thermal, SoC already resumed): no separate `mode_discharge_limit_w` — the whole target follows household load, capped by the linear thermal de-rating ceiling (400 W at 42 °C ramping to 0 W at 48 °C); the 250 W daytime battery-help cap does not apply here.
- `EVENING_CATCH_UP`: bounded by `EVENING_DISCHARGE_LIMIT_W` (800 W), the asymmetric smoothing, and the measured-load clamp.
- `NIGHT_BASE`: target equals the base load target (`night_base_w - NIGHT_BASE_RESERVE_W`), clamped to measured load.

## Current Limit Registers

The Solakon exposes writable battery charge and discharge current limit registers. A live test showed that `battery_max_discharge_current = 0 A` is accepted and can be restored, but it did not fully eliminate small battery discharge while remote active power was set to 800 W.

Therefore, current limit registers should not be part of the normal algorithm. They may remain documented as an experimental/manual option, but production control should use active-power targets, heartbeat writes, and sparse target changes.

## Constants

All algorithm thresholds are Ruby constants, not config values. `solakon.yml` only carries connection/feature settings (`host`, `port`, `unit_id`, `monitoring_enabled`, `control_enabled`, `stale_after_s`).

`SolakonReading` (battery safety):

- `MIN_SOC_PCT` = 10
- `RESUME_SOC_PCT` = 11
- `HOT_TEMP_C` = 42.0
- `HOT_RESUME_TEMP_C` = 41.8
- `CUTOFF_TEMP_C` = 48.0
- `PV_PRESENT_W` = 50
- `USABLE_CAPACITY_WH` = 1920

`ZeroExportController` (control tuning):

- `MAX_OUTPUT_W` = 800
- `DAY_BATTERY_HELP_W` = 250
- `EVENING_DISCHARGE_LIMIT_W` = 800
- `HOT_OUTPUT_LIMIT_W` = 400 (ceiling at `HOT_TEMP_C`; ramps linearly to 0 at `CUTOFF_TEMP_C`)
- `NORMAL_DEADBAND_W` = 50
- `BASE_DEADBAND_W` = 15
- `NIGHT_BASE_RESERVE_W` = 5
- `RISE_FACTOR` = 0.25
- `RISE_CAP_W` = 50
- `FALL_FACTOR` = 0.80

`ConsumptionReader`:

- `NIGHT_BASE_DAYS` = 7

`SunWindow`:

- `FALLBACK_SUNRISE_HOUR` = 6
- `FALLBACK_SUNSET_HOUR` = 20

## Summary

The controller should behave like this:

- During daylight or meaningful PV, prioritize PV directly into the house and allow only limited battery help.
- After sunset, discharge more actively only if the battery would otherwise remain too full by sunrise.
- Once base load is enough to reach the morning target, switch to a quiet base-load setpoint.
- Keep remote control alive with a watchdog heartbeat, even when the target is unchanged.
- Clamp smoothed targets to current measured load so falling loads do not cause avoidable export.
- Store battery temperature; treat thermal protection as the `PROTECTED` state with hysteresis (enter at 42.0 °C, leave at 41.8 °C), where the target follows household load down, capped at 400 W.
- On missing or stale critical data, prefer releasing control over holding an old risky target.
- All thresholds are Ruby constants owned by the relevant model/controller class, not `solakon.yml` config.
