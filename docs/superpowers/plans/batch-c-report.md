# Batch C Implementation Report (Tasks 7 & 8)

**Branch:** feature/govee-lights  
**Date:** 2026-06-27

---

## Task 7 — Per-light Turbo Stream reconcile

### Steps run

**Step 1 — Subscription tag in show.html.erb**  
Added `<%= turbo_stream_from "light_#{@light.key}" %>` directly after the opening `<div class="ld" ...>`.

**Step 2 — Failing test added**  
Added test "broadcasts a turbo stream replacing the power partial for the light" to `test/govee_status_handler_test.rb`.

**Step 3 — Verified failure**
```
bin/rails test test/govee_status_handler_test.rb -n "/turbo stream replacing the power/"
rake test: 1 runs, 1 failures, 0 errors
```
FAIL as expected (no `broadcast_replace_to` call yet).

**Step 4 — Implementation**  
Added `broadcast_turbo(key)` private method to `lib/govee_status_handler.rb` and called it from `handle_state` after the existing `broadcast(key, attrs)`.

**Step 5 — Tests pass**
```
bin/rails test test/govee_status_handler_test.rb
rake test: 11 runs, 0 failures
```
All 11 tests green including existing `"dashboard"`-broadcast tests.

**Commit:** `292c2ee feat(lights): per-light turbo stream for live power reconcile`

Files: `app/views/lights/show.html.erb`, `lib/govee_status_handler.rb`, `test/govee_status_handler_test.rb`

---

## Task 8 — Slim Stimulus controller + toast timer + fire-and-forget 204

### Steps run

**Step 1 — Tests updated (failing-first)**  
- Added new test "brightness responds 204 no_content for fire-and-forget"  
- Changed `assert_response :accepted` → `assert_response :no_content` for: brightness, effect, mood (reading), mood (sunset)

```
bin/rails test test/controllers/light_switches_controller_test.rb -n "/204 no_content/"
rake test: 1 runs, 1 failures, 0 errors
```
FAIL as expected (still returns `:accepted`).

**Step 2 — Controller: `head :accepted` → `head :no_content`**  
Changed the final `head :accepted` in `LightSwitchesController#create` to `head :no_content`.

```
bin/rails test test/controllers/light_switches_controller_test.rb
rake test: 19 runs, 0 failures
```

**Step 3 — Replaced `light_detail_controller.js`**  
Completely replaced with slim version: tabs + debounced sliders/wheel only. No DashboardChannel subscription, no zone logic, no toast logic.  
`static targets = ["panel", "temp"]` (includes `temp` for `hasTempTarget` in preset buttons).

**Step 4 — Created `toast_controller.js`**  
New file at `app/javascript/controllers/toast_controller.js`. Auto-dismisses toast after 5s on `connect()`.

**Step 5 — View cleanup in show.html.erb**  
Removed:
- `data-light-detail-max-zones-value="<%= @light.max_active_zones || 0 %>"` from root div
- `data-light-detail-target="wheel"` from the color picker input (kept `data-action="light-detail#wheel"`)
- `<div class="ld-error" data-light-detail-target="error"></div>` (entire line)

**Verification grep (plan's exact command, run via `rtk proxy` for raw output):**
```
rtk proxy grep -n "light-detail-target=\"\(lamp\|wheel\|error\|toast\|toastMsg\)\"\|max-zones-value\|#undoZone\|#on\b\|#off\b" app/views/lights/show.html.erb
exit=1
```
No matches — clean.

**Step 6 — Full suite failure found and fixed**  
The existing test `LightsControllerTest#test_zone_lamp_renders_a_Zonen_tab_and_one_card_per_zone,_main_badged` asserted on `data-light-detail-max-zones-value='2'` (line 122 of `lights_controller_test.rb`). This attribute was intentionally removed. The assertion was dropped; the test continues to verify the Zonen-tab, zone cards, main badge, and default-tab attribute.

**Final full suite:**
```
bin/rails test
rake test: 663 runs, 0 failures
Line Coverage: 81.9% (2357/2878) — above 70 gate
Branch Coverage: 79.46% (557/701) — above 71 gate
```

**Specific suites:**
```
bin/rails test test/controllers/light_switches_controller_test.rb test/controllers/lights_controller_test.rb
rake test: 35 runs, 0 failures
```

**Commit:** `788735f refactor(lights): slim light-detail JS to tabs+sliders, add toast timer, no_content for fire-and-forget`

Files: `app/javascript/controllers/`, `app/controllers/light_switches_controller.rb`, `app/views/lights/show.html.erb`, `test/controllers/light_switches_controller_test.rb`, `test/controllers/lights_controller_test.rb`

---

## Commit SHAs

```
git log --oneline -4
788735f refactor(lights): slim light-detail JS to tabs+sliders, add toast timer, no_content for fire-and-forget
292c2ee feat(lights): per-light turbo stream for live power reconcile
3214514 feat(lights): turn command optimistically persists on + replaces power partial
2d70c93 feat(lights): zone_undo command reverses auto-off and clears toast
```

---

## Deviations

1. **`lights_controller_test.rb` not in plan's Task 8 Step 8 `git add` list** — The test at line 122 asserting `data-light-detail-max-zones-value='2'` failed after the view cleanup (correct behavior: attribute was intentionally removed). The assertion was dropped and `lights_controller_test.rb` was added to the Task 8 commit. This is correct: the plan's view cleanup explicitly removes this attribute.

2. **RTK grep output vs raw grep** — The RTK proxy showed false-positive "2 matches in 2 files" for the verification grep. Running via `rtk proxy grep` returned exit=1 (no matches), confirming the view is clean.

---

## Concerns

None. Coverage stays well above the 70/71 gate. The `"dashboard"` broadcast is preserved in `GoveeStatusHandler` alongside the new `broadcast_turbo` call.

---

## Fix wave

**Date:** 2026-06-27  
**Branch:** feature/govee-lights

### Fix 1 — Mood & scene buttons converted to `button_to`

`app/views/lights/show.html.erb`:

- Replaced `<button data-action="light-detail#mood" data-light-detail-mood-param="...">` loop with `button_to light_command_path(light_key: @light.key), params: { command: "mood", mood: mood.id }, class: "ld-scene", form_class: "ld-inline-form"` using block form to preserve the inner `<span class="ld-scene-prev">` + `<span class="ld-scene-nm">` markup.
- Replaced `<button data-action="light-detail#scene" data-light-detail-scene-param="...">` loop with `button_to light_command_path(light_key: @light.key), params: { command: "effect", effect: scene }, class: "ld-scene", form_class: "ld-inline-form"` using block form to preserve the same inner spans.
- Pattern matches the existing power/zone partials (`_power.html.erb`, `_zone.html.erb`) which already use `button_to ... form_class: "ld-inline-form"`.

`test/controllers/lights_controller_test.rb` — updated assertions that matched old Stimulus data attributes to match the new form-based markup:
- `assert_select "button[data-action='light-detail#mood'][data-light-detail-mood-param='reading']"` → `assert_select "form.ld-inline-form input[name='mood'][value='reading']"`
- `assert_select "button[data-light-detail-mood-param='party']"` → `assert_select "form.ld-inline-form input[name='mood'][value='party']"`
- `assert_select "button[data-action='light-detail#scene'][data-light-detail-scene-param='Forest']"` → `assert_select "form.ld-inline-form input[name='effect'][value='Forest']"`
- `assert_select "button[data-light-detail-scene-param='Aurora']"` → `assert_select "form.ld-inline-form input[name='effect'][value='Aurora']"`
- `assert_select "button[data-action='light-detail#scene']", count: 0` → `assert_select "form.ld-inline-form input[name='effect']", count: 0`

### Fix 2 — Dangling `brightness` Stimulus target removed

`app/views/lights/show.html.erb`:

Removed `data-light-detail-target="brightness"` from the brightness range input. The `data-action="light-detail#brightness"` attribute was kept (slider still fires the action). The `static targets = ["panel", "temp"]` in the slim controller never declared `brightness`; the action reads `event.target.value` directly.

Updated corresponding test assertion:
- `assert_select "input[type=range][data-light-detail-target='brightness']"` → `assert_select "input[type=range][data-action='light-detail#brightness']"`

### Fix 3 — color / color_temp test status

Inspected `test/controllers/light_switches_controller_test.rb`. No tests exist for `color` or `color_temp` commands. File left unchanged.

### Grep verification

```
grep -n "light-detail#mood\|light-detail#scene\|light-detail-target=\"brightness\"\|mood-param\|scene-param" app/views/lights/show.html.erb
exit=1 (no matches)
```

### Test results

```
bin/rails test test/controllers/light_switches_controller_test.rb test/controllers/lights_controller_test.rb
rake test: 35 runs, 0 failures

bin/rails test
rake test: 663 runs, 0 failures
Line Coverage: 81.89% — above 70 gate
Branch Coverage: 79.45% — above 71 gate
```

### Commit SHA

(see git log below)
