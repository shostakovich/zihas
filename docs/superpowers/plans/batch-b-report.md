# Batch B Implementation Report

Tasks 3, 4, 5, 6 from `2026-06-27-lamp-widget-turbo-hotwire.md`.

## Steps Run

### Task 3: Zone command responds with Turbo Stream

**Failing test added:** "zone command responds with a turbo stream replacing the card"

```
bin/rails test test/controllers/light_switches_controller_test.rb -n "/responds with a turbo stream/"
→ 1 runs, 1 failures, 0 errors  (FAIL as expected)
```

**Implementation:** Updated `when "zone"` to call `return respond_zone(light, params[:zone])`.
Added private helper `respond_zone(light, *zone_keys, toast: nil)` that renders turbo_stream replace for each zone key.

**Adjusted existing assertions:**
- "zone command toggles a valid zone": `assert_response :accepted` → `assert_response :success`
- "zone command persists the zone state": `assert_response :accepted` → `assert_response :success`
  (Both test zone commands that now return turbo_stream 200 instead of head 202.)

```
bin/rails test test/controllers/light_switches_controller_test.rb
→ 15 runs, 0 failures  (PASS)
```

**Commit:** `9944d1c feat(lights): zone command responds with turbo_stream card replace`

---

### Task 4: Server-driven max-2-auto-off + Toast

**Failing test added:** "turning on a side zone over the limit evicts an on side and shows a toast"

```
bin/rails test test/controllers/light_switches_controller_test.rb -n "/evicts/"
→ 1 runs, 1 failures, 0 errors  (FAIL as expected)
```

**Implementation:** Expanded `when "zone"` to compute eviction via new `evict_for(light, zone)` helper.
When a side zone is turned on and the on-zone count already meets `max_active_zones`, the other on-side is turned off first (persisted + MQTT), then a toast stream is appended.

Added private helper `evict_for(light, zone)` — returns the key of another on-side zone to evict, or nil.

```
bin/rails test test/controllers/light_switches_controller_test.rb
→ 16 runs, 0 failures  (PASS)
```

**Commit:** `94d85ae feat(lights): server-driven max-zone auto-off with toast`

---

### Task 5: zone_undo command

**Failing test added:** "zone_undo restores the victim, turns off the added zone and clears the toast"

```
bin/rails test test/controllers/light_switches_controller_test.rb -n "/zone_undo restores/"
→ 1 runs, 1 failures, 0 errors  (FAIL as expected — 422 because when "zone_undo" didn't exist)
```

**Implementation:** Added `when "zone_undo"` branch before `when "mood"`. Validates both victim and added are zones on the light. Persists and sends MQTT commands for both sides, then calls `respond_zone` with `toast: { message: nil, undo: nil }` to clear the toast.

```
bin/rails test test/controllers/light_switches_controller_test.rb
→ 17 runs, 0 failures  (PASS)
```

**Commit:** `2d70c93 feat(lights): zone_undo command reverses auto-off and clears toast`

---

### Task 6: Power command responds with Turbo Stream

**Failing test added:** "turn optimistically persists on and replaces the power partial"

```
bin/rails test test/controllers/light_switches_controller_test.rb -n "/optimistically persists on/"
→ 1 runs, 0 failures, 1 errors  (ERROR as expected — LightState nil because not persisted yet)
```

**Implementation:** Updated `when "turn"` to extract `on` variable, call `LightState.record_state(light.key, on: on)`, then `return respond_power(light)`.
Added private helper `respond_power(light)` that renders turbo_stream replace for `light_power`.

**Adjusted existing assertions (per plan Task 6 Step 4 note):**
- "turn calls GoveeCommander and responds 202": `assert_response :accepted` → `assert_response :success`
- "turn routes a zone lamp through powerSwitch": `assert_response :accepted` → `assert_response :success`
- "turn still uses the light command for a simple lamp": `assert_response :accepted` → `assert_response :success`

```
bin/rails test test/controllers/light_switches_controller_test.rb
→ 18 runs, 0 failures  (PASS)
```

**Commit:** `3214514 feat(lights): turn command optimistically persists on + replaces power partial`

---

## Commit SHAs

```
git log --oneline -6

3214514 feat(lights): turn command optimistically persists on + replaces power partial
2d70c93 feat(lights): zone_undo command reverses auto-off and clears toast
94d85ae feat(lights): server-driven max-zone auto-off with toast
9944d1c feat(lights): zone command responds with turbo_stream card replace
24e13f8 refactor(lights): extract power/zone/toast partials with stable DOM ids   (Task 2, previous batch)
5050f91 fix(lights): persist zone_states on zone command so it survives reload      (Task 1, previous batch)
```

## Adjusted Existing Assertions

| Test | Was | Now | Reason |
|------|-----|-----|--------|
| zone command toggles a valid zone | `:accepted` | `:success` | Task 3: zone now returns turbo_stream (200 not 202) |
| zone command persists the zone state | `:accepted` | `:success` | Task 3: same — zone returns turbo_stream |
| turn calls GoveeCommander and responds 202 | `:accepted` | `:success` | Task 6: turn now returns turbo_stream (200 not 202) |
| turn routes a zone lamp through powerSwitch | `:accepted` | `:success` | Task 6: same |
| turn still uses the light command for a simple lamp | `:accepted` | `:success` | Task 6: same |

## Deviations

None. All code was applied verbatim from the plan.

One minor observation: the plan's Step 2 for Task 4 says to run with `-n "/evicts the other side/"` but the test name contains "evicts an on side". The broader pattern `/evicts/` was used instead. No functional impact.

## Concerns

None. All 18 tests pass. The `respond_zone` helper is reused cleanly across Tasks 3, 4, and 5 as designed.
