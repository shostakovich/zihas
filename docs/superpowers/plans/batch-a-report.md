# Batch A Report — Task 1 + Task 2

**Date:** 2026-06-27
**Branch:** feature/govee-lights
**Executor:** Claude Sonnet 4.6

---

## Summary

Task 1 and Task 2 from `2026-06-27-lamp-widget-turbo-hotwire.md` are implemented and committed. Two commits total.

---

## Task 1: Persist zone_states on zone command

### Step 1 — Added failing test

File: `test/controllers/light_switches_controller_test.rb`

Added:
```ruby
test "zone command persists the zone state" do
  Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
  GoveeCommander.stub(:set_zone, ->(*, **) {}) do
    post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "rippleLightToggle", on: "true" }
  end
  assert_response :accepted
  assert_equal({ "rippleLightToggle" => true }, LightState.find_by(light_key: "UP1").zone_states)
end
```

### Step 2 — Run failing test

Command: `bin/rails test test/controllers/light_switches_controller_test.rb -n "/zone command persists/"`

Output (abbreviated):
```
Error:
LightSwitchesControllerTest#test_zone_command_persists_the_zone_state:
NoMethodError: undefined method 'zone_states' for nil
1 runs, 1 assertions, 0 failures, 1 errors, 0 skips
```

Result: **FAIL** (as expected — no LightState record was created because zone command did not persist)

### Step 3 — Implement fix

File: `app/controllers/light_switches_controller.rb`

Replaced `when "zone"` branch:
```ruby
when "zone"
  return head :unprocessable_entity unless light.zones.include?(params[:zone])
  on = cast_bool(params[:on])
  LightState.record_zone_state(light.key, params[:zone], on)
  GoveeCommander.set_zone(light, zone: params[:zone], on: on, **opts)
```

### Step 4 — Run all tests

Command: `bin/rails test test/controllers/light_switches_controller_test.rb`

Output: `ok rake test: 14 runs, 0 failures`

Result: **PASS** (14 tests, 0 failures, 0 errors)

### Step 5 — Commit

```
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "fix(lights): persist zone_states on zone command so it survives reload"
```

**SHA: 5050f91**

---

## Task 2: Extract partials (_power, _zone, _toast)

### Step 1 — Added failing test

File: `test/controllers/lights_controller_test.rb`

Added:
```ruby
test "show renders a zone card with id and reflects persisted zone_states" do
  light = Light.create!(name: "Up", key: "UP9", zones: %w[bottomLightToggle rippleLightToggle])
  LightState.record_zone_state("UP9", "rippleLightToggle", true)
  get light_url(key: "UP9")
  assert_response :success
  assert_select "#zone_rippleLightToggle"
  assert_select "#zone_rippleLightToggle.ld-zone:not(.off)"
  assert_select "#zone_bottomLightToggle.ld-zone.off"
end
```

### Step 2 — Run failing test

Command: `bin/rails test test/controllers/lights_controller_test.rb -n "/show renders a zone card/"`

Output (abbreviated):
```
Failure:
LightsControllerTest#test_show_renders_a_zone_card_with_id_and_reflects_persisted_zone_states:
Expected at least 1 element matching "#zone_rippleLightToggle", found 0.
1 runs, 3 assertions, 1 failures, 0 errors, 0 skips
```

Result: **FAIL** (as expected — zone divs had no `id` attribute)

### Steps 3–5 — Create partials

Created verbatim from plan:
- `app/views/lights/_power.html.erb`
- `app/views/lights/_zone.html.erb`
- `app/views/lights/_toast.html.erb`

### Step 6 — Update show.html.erb

Replaced three sections in `app/views/lights/show.html.erb`:
1. Hero block (old 7-line ld-hero div) → `<%= render "lights/power", light: @light, row: @row %>`
2. Zone each loop (old 13-line inline zone divs) → `<%= render "lights/zone", zone: zone, light_key: @light.key %>`
3. Toast block (old 4-line ld-toast div) → `<%= render "lights/toast", message: nil, undo: nil %>`

### Step 7 — CSS

File: `app/assets/stylesheets/application.css`

Appended to end:
```css
.ld-inline-form { display: contents; }
```

### Step 8 — Run tests

Command: `bin/rails test test/controllers/lights_controller_test.rb`

Output: `ok rake test: 16 runs, 0 failures`

Result: **PASS** (16 tests, 0 failures, 0 errors)

### Step 9 — Commit

```
git add app/views/lights/ test/controllers/lights_controller_test.rb app/assets
git commit -m "refactor(lights): extract power/zone/toast partials with stable DOM ids"
```

**SHA: 24e13f8**

---

## Git Log

```
24e13f8 refactor(lights): extract power/zone/toast partials with stable DOM ids
5050f91 fix(lights): persist zone_states on zone command so it survives reload
d93acc4 docs(lights): implementation plan for lamp widget Turbo+Hotwire rewrite
```

---

## Deviations from plan

### 1. Existing test `"show has hero, brightness, white slider and tabs"` updated

**What happened:** The plan's Task 2 Step 6 replaced the hero block's plain `<button data-action="light-detail#on">` buttons with `button_to` forms. An existing test at `test/controllers/lights_controller_test.rb:60` asserted `assert_select "button[data-action='light-detail#on']"` which no longer matched the new markup.

**Resolution:** Updated that one assertion from `assert_select "button[data-action='light-detail#on']"` to `assert_select "#light_power .ld-pill"`. This still verifies the hero contains power buttons, now matching the `button_to`-rendered submit buttons inside `#light_power`. No test was removed; one assertion was adapted.

**Why:** The plan's Step 8 expected PASS for all tests. The plan did not mention updating this assertion, but the markup change made it unavoidable. The instruction "do not remove existing ones" was honored — the test remains with an updated selector.

---

## Concerns

None. Coverage gate (line 70% / branch 71%) is only enforced when running the full suite; single-file runs show low coverage numbers because most of the codebase is not exercised. The plan does not require running the full suite for Task 1 or Task 2.
