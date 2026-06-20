# Solakon One Control Algorithm Design

Date: 2026-06-20  
Status: Draft for review

## Background

The Solakon One should harvest PV surplus and later release that energy to improve self-consumption. The controller should not chase every short household load spike. Small grid import or export around 10 W is acceptable. The main goals are: PV directly to the house first, useful battery discharge later, low SoC and thermal protection, and sparse but reliable Modbus writes.

The existing Solakon monitoring path reads inverter state regularly. Control is optional and writes Modbus values only when `control_enabled` is true. This design extends the current zero-export feed-forward controller instead of adding a separate control system.

## Existing Building Blocks

- `ConsumptionReader#current_consumption_w` is the household load input: sum of fresh consumer plug samples.
- `ConsumptionReader#guaranteed_floor_w` remains useful as a conservative fallback load estimate.
- `SolakonClient` reads SoC, PV power, AC active power, and battery power.
- `SolakonClient::REMOTE_TIMEOUT_S` is 150 seconds. Remote control must be rearmed before this watchdog expires.
- `SunCalc.sunrise` and `SunCalc.sunset` provide sunrise and sunset from the configured weather location and timezone.

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

Purpose: avoid intentional battery discharge.

Enter when:

- SoC is at or below 10%.
- Battery temperature protection requires a strong AC output cap.
- Control state is unsafe because required sensor data is missing.

Exit low-SoC protection when:

- SoC is at least 11% for a fresh reading. If this flaps in practice, require two consecutive fresh readings.

Behavior:

- Do not intentionally request battery discharge.
- Use a PV-priority target at most, or release remote control when the safest action is to let the inverter handle itself.
- The hard lower SoC boundary is still the inverter minimum SoC setting; the controller is best-effort above that.

### PV_PRIORITY

Default daylight mode and also any time PV is meaningfully present. Battery discharge is allowed, including during the day, but only after PV has covered as much load as possible.

```text
pv_direct_w = min(pv_w, household_load_w)
remaining_load_w = max(0, household_load_w - pv_direct_w)

battery_help_w = min(
  remaining_load_w,
  mode_discharge_limit_w,
  soc_discharge_limit_w
)

raw_target_w = pv_direct_w + battery_help_w
target_w = apply_output_caps(raw_target_w)
```

Examples:

- PV 100 W, load 386 W, low SoC: target about 100 W.
- PV 100 W, load 386 W, healthy battery: target may be 100 W plus limited battery help.

### EVENING_CATCH_UP

Used after sunset when the battery has more usable energy than expected base load can consume by sunrise. It may discharge more than base load, but must not follow short appliance peaks.

Use asymmetric smoothing:

- Increase target slowly.
- Decrease target quickly.
- Always clamp to the current fresh measured load.

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

- Use the last 7 nights by default.
- A night bucket is between sunset and sunrise, excluding the first hour after sunset and the last hour before sunrise to avoid evening and morning activity.
- If there is not enough night data, fall back to `guaranteed_floor_w` and then to a conservative configured default.

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

## Transitions

```text
any state -> PROTECTED
  when SoC <= 10%, required sensor data is missing, or thermal protection demands it

PROTECTED -> PV_PRIORITY
  when SoC >= 11% and PV is present or it is daytime

PROTECTED -> NIGHT_BASE
  when SoC >= 11%, it is night, and usable_wh <= base_need_wh

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

If Solakon read fails:

- Do not compute a new target from stale inverter data.
- Log the failure and count consecutive failures.
- After repeated failures, release remote control so the inverter returns to its own default behavior.

If household load is unavailable:

- Use `guaranteed_floor_w` as the conservative load estimate.
- If both live load and floor are unavailable or implausible, release control instead of holding an old high target.

If a write fails:

- Count consecutive failures.
- After repeated failures, attempt `release_control!`.

## Temperature

Store battery temperature in `solakon_readings` as `battery_temperature_c`.

Use the BMS maximum temperature register as the protection signal. The Home Assistant integration identifies `bms1_max_temp` as register `37617`, signed 16-bit, scale 10, in Celsius.

```text
raw_target_w = state_target_before_output_caps

if battery_temperature_c >= 42 C:
  target_w = min(raw_target_w, 400 W)
else:
  target_w = min(raw_target_w, 800 W)
```

This limit applies to the whole AC target, not only to battery help. The intent is to reduce inverter heat; storing surplus in the battery may still be preferable to pushing high AC power through the outside socket while hot.

## Discharge Limits

Make `limited_allowed_discharge` explicit:

```text
battery_help_w = min(
  remaining_load_w,
  mode_discharge_limit_w,
  soc_discharge_limit_w
)
```

Suggested defaults:

- `soc_discharge_limit_w = 0` at or below 10% and until resume at 11%.
- `mode_discharge_limit_w` is lower in `PV_PRIORITY`, higher in `EVENING_CATCH_UP`, and equal to base target in `NIGHT_BASE`.

## Current Limit Registers

The Solakon exposes writable battery charge and discharge current limit registers. A live test showed that `battery_max_discharge_current = 0 A` is accepted and can be restored, but it did not fully eliminate small battery discharge while remote active power was set to 800 W.

Therefore, current limit registers should not be part of the normal algorithm. They may remain documented as an experimental/manual option, but production control should use active-power targets, heartbeat writes, and sparse target changes.

## Open Parameters

These values should be constants or config values with conservative defaults:

- `battery_capacity_wh`
- `resume_soc_pct`, default 11
- `max_day_battery_help_w`
- `max_evening_discharge_w`
- `hot_battery_temp_c`, default 42
- `hot_ac_output_limit_w`, default 400
- normal write deadband, default 50 W
- base-load write deadband, default 15 W
- base-load reserve, default 5 W
- heartbeat interval, default 120 s
- night base history window, default 7 nights

## Summary

The controller should behave like this:

- During daylight or meaningful PV, prioritize PV directly into the house and allow only limited battery help.
- After sunset, discharge more actively only if the battery would otherwise remain too full by sunrise.
- Once base load is enough to reach the morning target, switch to a quiet base-load setpoint.
- Keep remote control alive with a watchdog heartbeat, even when the target is unchanged.
- Clamp smoothed targets to current measured load so falling loads do not cause avoidable export.
- Store battery temperature and cap total AC output at high temperature.
- On missing or stale critical data, prefer releasing control over holding an old risky target.
