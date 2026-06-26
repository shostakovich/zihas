# Govee Lamp UI — Phase 2: Szenen, Stimmungen & Plüsch-Assets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill the lamp detail page's `Szenen` tab with curated "Stimmungen" (work on any lamp) plus each device's real Govee firmware scenes, and replace the Phase-1 CSS-glow plush placeholder with per-SKU plush artwork in both the list tile and the detail hero.

**Architecture:** Additive on top of the Phase-1 command/status pipeline. **Part A (Szenen & Stimmungen):** `GoveeCommander` gains `set_effect` (publishes `{"state":"ON","effect":"<name>"}` to the existing light command topic — verified against the vendored govee2mqtt source `service/hass.rs:298`). A new `GoveeSceneDiscoveryHandler` consumes the retained scene-`select` discovery config govee2mqtt publishes and persists the per-device scene list on `lights.firmware_scenes`. The `Szenen` tab renders four hardcoded `LightMood`s plus the device's scenes; taps POST `mood`/`effect` commands. **Part B (Plüsch-Assets):** `Light#plush_type` maps SKU → asset family; a shared partial renders the on/off webp pair; CSS swaps and tints them, keyed off the on/off classes the Phase-1 Stimulus controllers already toggle. No account-login dependency (everything works api-key + LAN).

**Tech Stack:** Rails 8.1, Hotwire/Stimulus, ActionCable (DashboardChannel), Propshaft assets, Minitest + fixtures, plain CSS in `app/assets/stylesheets/application.css`, MQTT via `GoveeCommander` / `MqttRouter`.

## Grounding (verified against the live bridge + vendored source)

- **Scene activation:** the light command topic `gv2mqtt/light/<id>/command` accepts an `effect` field; govee2mqtt routes it to `device_set_scene` (`vendor/govee2mqtt/src/service/hass.rs:258,298-302`). So a scene is set with the *same* topic and publish helper Phase 1 already uses — no new MQTT topic needed on our side.
- **Scene discovery:** govee2mqtt publishes a retained HA `select` config at **`gv2mqtt/select/gv2mqtt-<id>-mode-scene/config`** (`vendor/.../hass_mqtt/instance.rs:24-30` builds `{disco}/select/{unique_id}/config`; `select.rs:115-134` builds the `SceneModeSelect`). Payload fields we use: `unique_id` (ends with `-mode-scene`), `command_topic` = `gv2mqtt/<id>/set-mode-scene`, `options` = the array of scene-name strings. The `<id>` in `command_topic` is `topic_safe_id(device)` — the **same value** `GoveeDiscoveryHandler` already stores as `Light#key` (it parses it from `gv2mqtt/light/<id>/state`).
- A device only gets the scene `select` when it actually has scenes (`select.rs:111` returns `None` for an empty list), so absence is normal and must be tolerated.

## Global Constraints

- Spec: [docs/superpowers/specs/2026-06-26-govee-lamp-ui-design.md](../specs/2026-06-26-govee-lamp-ui-design.md) — sections "Szenen-Tab", "Plüsch-Assets", "Backend-Auswirkungen". Visual reference: [scenes-and-tile.html](../specs/2026-06-26-govee-lamp-ui-mockups/scenes-and-tile.html) (Szenen tab = Stimmungen grid above, Govee-scene grid below), [tile-v2.html](../specs/2026-06-26-govee-lamp-ui-mockups/tile-v2.html) (plush knob).
- German UI copy throughout.
- Lights are addressed by `:key`, never `:id` (`Light#to_param` returns `key`).
- Commands go to `POST /lights/:light_key/command` (`light_command_url`). Phase 2 ADDS two command values: `effect` (param `effect` = scene name) and `mood` (param `mood` = mood id). Existing `turn|brightness|color|color_temp` are unchanged.
- **Stimulus action params MUST be namespaced by the controller identifier:** for `data-controller="light-detail"`, write `data-light-detail-<name>-param="…"` and read it as `event.params.<name>`. (A non-namespaced `data-<name>-param` yields `undefined` — this exact bug shipped and was caught in Phase 1's final review. Do not repeat it.)
- **Scene activation uses the light command topic** (`{"state":"ON","effect":"<name>"}`), NOT the `set-mode-scene` topic — keeps everything in `GoveeCommander.publish`.
- **SKU → plush type map (exact):** `H60B0`→`uplighter`, `H607C`→`floorlamp`, `H6038`→`sconce`, `H60A6`→`ceiling`; any other / blank SKU → `generic`. Match case-insensitively. (Resolved with the user: H6038 is the Wall Sconce; the ordered Ceiling is H60A6.)
- **Plush rendering follows the existing plug-knob technique:** the plug knob is an empty `<button class="sw-knob">` whose plush image is a CSS `background-image: url(switch_plush_on.webp)` (`.sw-knob.off` → `switch_plush_off.webp`). Lamps mirror this — a per-type CSS class on the knob/hero element, NOT an inline `<img>`. Asset filenames (Propshaft, in `app/assets/images/`): `lamp_<type>_on.webp` / `lamp_<type>_off.webp` for `<type>` ∈ `uplighter, floorlamp, sconce, ceiling, generic` (10 files).
- **Asset presence:** `bin/ci` does not precompile assets (`config/ci.rb`) and controller tests render a `<link>`, not inline CSS, so the suite passes without the webp files — tests assert the plush CSS *class*, not an image src. The files are only needed for the running app to serve `application.css` (Propshaft raises `MissingAssetError` for a missing `url()` target when it compiles the stylesheet). The user supplies the final artwork; Task 10 Step 1 stages placeholders so `bin/dev` renders before the art lands.
- Design tokens (defined in `:root`, added Phase-1 Task 0): radii `--radius-sm/md/lg/pill`, `--accent-tint`/`--accent-tint-2`/`--accent-ink`, `--accent-bg`, `--surface-sunk`, `--surface-hover`, `--danger`, `--online`, `--offline`, `--focus-ring`, `--glow-accent`. All new CSS consumes tokens, not new literals (one-off radii like 10px/11px and multi-stop gradients may stay literal, matching Phase 1).
- Run the full check with `bin/ci` before declaring done; it must run with the dev stack **stopped** (SQLite lock). Individual tests: `bin/rails test TEST=path -n test_name`.
- JS and CSS have no unit-test harness here. For those steps "verify" = render-assert markup/data-attributes in a controller test where possible, plus a stated manual check. Do not claim JS/CSS behaviour is tested when it is only manually checked.

## What is NOT in Phase 2 (explicit deferrals)

- **Active-scene/active-mood reflection** (persisting which scene is currently live and highlighting it on reload): deferred. Feedback after a tap comes from the optimistic `pending`/broadcast reconcile already in place; the selection highlight is client-only for the current page view. Spec "Backend-Auswirkungen #6" (status broadcast of active scene) is a later follow-up.
- **Uplighter zones / segments / max-2 rule** — still Phase 3 (separate plan). Scene/effect on a zoned lamp still applies to the whole device here.
- **Real plush artwork generation** — out of scope for code; the user provides the webp binaries. This plan only wires them (with staged placeholders so it is testable).

## File Structure

- Modify `lib/govee_commander.rb` — add `set_effect`.
- Modify `test/govee_commander_test.rb` — `set_effect` test.
- Create `app/models/light_mood.rb` — curated Stimmungen (pure value object).
- Create `test/models/light_mood_test.rb`.
- Modify `app/controllers/light_switches_controller.rb` — `effect` + `mood` commands.
- Modify `test/controllers/light_switches_controller_test.rb`.
- Create `db/migrate/<ts>_add_firmware_scenes_to_lights.rb` — `lights.firmware_scenes` text column.
- Modify `db/schema.rb` (regenerated by the migration).
- Modify `app/models/light.rb` — serialize `firmware_scenes`, add `plush_type`.
- Modify `test/models/light_test.rb`.
- Create `lib/govee_scene_discovery_handler.rb` — scene-select discovery → `firmware_scenes`.
- Create `test/govee_scene_discovery_handler_test.rb`.
- Modify `bin/ziwoas_collector` — register the new handler.
- Create `app/helpers/lights_helper.rb` — `scene_gradient`.
- Create `test/helpers/lights_helper_test.rb`.
- Modify `app/views/lights/show.html.erb` — replace the Szenen stub panel (Task 6); add the per-type plush class to the hero lamp (Task 10).
- Modify `app/javascript/controllers/light_detail_controller.js` — `mood`/`scene` actions (Task 7); toggle the hero lamp's `off` state on broadcast (Task 10).
- Modify `app/views/switches/_light_card.html.erb` — add the per-type plush class to the knob.
- Modify `app/assets/stylesheets/application.css` — scene grid + per-SKU plush `background-image` styles (same CSS technique as `.sw-knob`).
- Modify `test/controllers/lights_controller_test.rb` and `test/controllers/switches_controller_test.rb` — scene render + plush-class assertions.
- Add `app/assets/images/lamp_*_{on,off}.webp` (10 files; final art from user, placeholders staged for local dev).

---

## Part A — Szenen & Stimmungen

### Task 1: `GoveeCommander.set_effect`

**Files:**
- Modify: `lib/govee_commander.rb`
- Test: `test/govee_commander_test.rb`

**Interfaces:**
- Consumes: `GoveeCommander.publish` (existing), `light.key`.
- Produces: `GoveeCommander.set_effect(light, effect:, mqtt_config:, mqtt_factory: nil)` → publishes `{"state"=>"ON","effect"=><string>}` to `gv2mqtt/light/<key>/command`.

- [ ] **Step 1: Write the failing test**

Append inside `class GoveeCommanderTest` in `test/govee_commander_test.rb` (before the final `end`):

```ruby
  test "set_effect includes state ON and the effect name" do
    c = FakeMqtt.new
    GoveeCommander.set_effect(@light, effect: "Forest", **opts(c))
    topic, payload = c.published.first
    assert_equal "gv2mqtt/light/14ABDB4844064B60/command", topic
    assert_equal({ "state" => "ON", "effect" => "Forest" }, JSON.parse(payload))
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test TEST=test/govee_commander_test.rb -n test_set_effect_includes_state_ON_and_the_effect_name`
Expected: FAIL — `NoMethodError: undefined method 'set_effect'`.

- [ ] **Step 3: Implement `set_effect`**

In `lib/govee_commander.rb`, add after `set_color_temp` (before `kelvin_to_mired`):

```ruby
  def self.set_effect(light, effect:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "effect" => effect.to_s }, mqtt_config:, mqtt_factory:)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test TEST=test/govee_commander_test.rb`
Expected: PASS (all existing + the new one).

- [ ] **Step 5: Commit**

```bash
git add lib/govee_commander.rb test/govee_commander_test.rb
git commit -m "Add GoveeCommander.set_effect (activate a firmware scene via the light command topic)"
```

---

### Task 2: `LightMood` curated Stimmungen

**Files:**
- Create: `app/models/light_mood.rb`
- Test: `test/models/light_mood_test.rb`

**Interfaces:**
- Produces (used by Task 3 controller + Task 6 view):
  - `LightMood::ALL -> [LightMood::Mood]` where `Mood = Data.define(:id, :name, :emoji, :gradient, :brightness, :color, :color_temp_k)`; `color` is `{r:,g:,b:}` or `nil`; exactly one of `color`/`color_temp_k` is set per mood.
  - `LightMood.find(id) -> Mood | nil`.

- [ ] **Step 1: Write the failing tests**

Create `test/models/light_mood_test.rb`:

```ruby
require "test_helper"

class LightMoodTest < ActiveSupport::TestCase
  test "ALL contains the four curated moods with stable ids" do
    assert_equal %w[sunset reading cinema party], LightMood::ALL.map(&:id)
  end

  test "every mood is renderable and applies exactly one colour mode" do
    LightMood::ALL.each do |m|
      assert m.name.present?, "#{m.id} needs a name"
      assert m.emoji.present?, "#{m.id} needs an emoji"
      assert m.gradient.start_with?("linear-gradient"), "#{m.id} needs a preview gradient"
      assert m.brightness.is_a?(Integer)
      assert m.color.nil? ^ m.color_temp_k.nil?, "#{m.id} must set color XOR color_temp_k"
    end
  end

  test "reading is a warm-white mood" do
    m = LightMood.find("reading")
    assert_nil m.color
    assert_equal 3000, m.color_temp_k
  end

  test "find returns nil for an unknown id" do
    assert_nil LightMood.find("nope")
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test TEST=test/models/light_mood_test.rb`
Expected: FAIL — `NameError: uninitialized constant LightMood`.

- [ ] **Step 3: Implement the value object**

Create `app/models/light_mood.rb`:

```ruby
# Curated "Stimmungen" for the lamp detail page's Szenen tab. Each mood is a
# colour/temperature/brightness recipe that works on any lamp (composed from the
# same primitives as GoveeCommander). Pure value object — no persistence.
class LightMood
  Mood = Data.define(:id, :name, :emoji, :gradient, :brightness, :color, :color_temp_k)

  ALL = [
    Mood.new(id: "sunset", name: "Sonnenuntergang", emoji: "🌅",
             gradient: "linear-gradient(135deg, #ffb24d, #ff7a3d)",
             brightness: 60, color: { r: 255, g: 122, b: 61 }, color_temp_k: nil),
    Mood.new(id: "reading", name: "Lesen", emoji: "📖",
             gradient: "linear-gradient(135deg, #fff4e0, #ffd9a0)",
             brightness: 80, color: nil, color_temp_k: 3000),
    Mood.new(id: "cinema", name: "Kino", emoji: "🎬",
             gradient: "linear-gradient(135deg, #1a1a2e, #4d3a8c)",
             brightness: 15, color: { r: 77, g: 58, b: 140 }, color_temp_k: nil),
    Mood.new(id: "party", name: "Party", emoji: "🎉",
             gradient: "linear-gradient(135deg, #ff4d6d, #7c5cff, #22b8cf)",
             brightness: 100, color: { r: 255, g: 77, b: 109 }, color_temp_k: nil)
  ].freeze

  def self.find(id) = ALL.find { |m| m.id == id }
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/models/light_mood_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/light_mood.rb test/models/light_mood_test.rb
git commit -m "Add LightMood curated Stimmungen value object"
```

---

### Task 3: `effect` + `mood` commands in `LightSwitchesController`

**Files:**
- Modify: `app/controllers/light_switches_controller.rb`
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: `GoveeCommander.set_effect` (Task 1), `LightMood.find` (Task 2), existing `GoveeCommander.turn/set_brightness/set_color/set_color_temp`.
- Produces: two new `command` values on `POST /lights/:light_key/command`:
  - `effect` — param `effect` (string) → `set_effect`.
  - `mood` — param `mood` (id) → `turn ON` + `set_brightness` + (`set_color_temp` if the mood is white, else `set_color`); unknown id → `422`.

- [ ] **Step 1: Write the failing tests**

Append inside `class LightSwitchesControllerTest` (before the final `end`) in `test/controllers/light_switches_controller_test.rb`:

```ruby
  test "effect forwards the scene name" do
    GoveeCommander.stub :set_effect, ->(l, **kw) { @calls << [ l.key, kw[:effect] ] } do
      post light_command_url(light_key: @light.key), params: { command: "effect", effect: "Forest" }
    end
    assert_response :accepted
    assert_equal [ [ "A1B2C3D4E5F60030", "Forest" ] ], @calls
  end

  test "mood applies turn, brightness and colour-temp for a white mood (reading)" do
    GoveeCommander.stub :turn, ->(l, **kw) { @calls << [ :turn, kw[:on] ] } do
      GoveeCommander.stub :set_brightness, ->(l, **kw) { @calls << [ :brightness, kw[:value] ] } do
        GoveeCommander.stub :set_color_temp, ->(l, **kw) { @calls << [ :temp, kw[:kelvin] ] } do
          post light_command_url(light_key: @light.key), params: { command: "mood", mood: "reading" }
        end
      end
    end
    assert_response :accepted
    assert_equal [ [ :turn, true ], [ :brightness, 80 ], [ :temp, 3000 ] ], @calls
  end

  test "mood applies colour for an rgb mood (sunset)" do
    GoveeCommander.stub :turn, ->(*, **) {} do
      GoveeCommander.stub :set_brightness, ->(*, **) {} do
        GoveeCommander.stub :set_color, ->(l, **kw) { @calls << [ kw[:r], kw[:g], kw[:b] ] } do
          post light_command_url(light_key: @light.key), params: { command: "mood", mood: "sunset" }
        end
      end
    end
    assert_response :accepted
    assert_equal [ [ 255, 122, 61 ] ], @calls
  end

  test "unknown mood returns 422" do
    post light_command_url(light_key: @light.key), params: { command: "mood", mood: "nope" }
    assert_response :unprocessable_entity
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test TEST=test/controllers/light_switches_controller_test.rb`
Expected: FAIL — the `effect`/`mood` commands hit the `else` branch → `422` for `effect` (assertion mismatch) and the mood stubs are never called.

- [ ] **Step 3: Implement the commands**

In `app/controllers/light_switches_controller.rb`, add two `when` branches inside the `case params[:command]` (after the `color_temp` branch, before `else`):

```ruby
    when "effect"
      GoveeCommander.set_effect(light, effect: params[:effect].to_s, **opts)
    when "mood"
      return head :unprocessable_entity unless apply_mood(light, params[:mood])
```

Then add the private helper (after `cast_bool`):

```ruby
  def apply_mood(light, id)
    mood = LightMood.find(id)
    return false unless mood

    GoveeCommander.turn(light, on: true, **opts)
    GoveeCommander.set_brightness(light, value: mood.brightness, **opts) if mood.brightness
    if mood.color_temp_k
      GoveeCommander.set_color_temp(light, kelvin: mood.color_temp_k, **opts)
    elsif mood.color
      GoveeCommander.set_color(light, r: mood.color[:r], g: mood.color[:g], b: mood.color[:b], **opts)
    end
    true
  end
```

(The `head :accepted` at the end of `create` and the `rescue GoveeCommander::Error` already cover both new commands.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/controllers/light_switches_controller_test.rb`
Expected: PASS (existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "Add effect and mood commands to LightSwitchesController"
```

---

### Task 4: `lights.firmware_scenes` column + Light accessors

**Files:**
- Create: `db/migrate/<timestamp>_add_firmware_scenes_to_lights.rb`
- Modify: `db/schema.rb` (regenerated)
- Modify: `app/models/light.rb`
- Test: `test/models/light_test.rb`

**Interfaces:**
- Produces: `Light#firmware_scenes -> Array<String>` (never nil; `[]` when unset), writable with an Array, JSON-serialised in a `text` column. Used by Task 5 (writer) and Task 6 (reader).

- [ ] **Step 1: Write the failing tests**

Append inside `class LightTest` (before the final `end`) in `test/models/light_test.rb`:

```ruby
  test "firmware_scenes defaults to an empty array" do
    light = Light.create!(name: "Decke", key: "A1B2C3D4E5F60100")
    assert_equal [], light.reload.firmware_scenes
  end

  test "firmware_scenes round-trips an array of names" do
    light = Light.create!(name: "Decke", key: "A1B2C3D4E5F60101",
                          firmware_scenes: %w[Forest Aurora])
    assert_equal %w[Forest Aurora], light.reload.firmware_scenes
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test TEST=test/models/light_test.rb -n "/firmware_scenes/"`
Expected: FAIL — `unknown attribute 'firmware_scenes'`.

- [ ] **Step 3: Generate and write the migration**

Run: `bin/rails generate migration AddFirmwareScenesToLights firmware_scenes:text`
Then replace the generated migration body with (keep the generated class name / timestamp):

```ruby
class AddFirmwareScenesToLights < ActiveRecord::Migration[8.1]
  def change
    add_column :lights, :firmware_scenes, :text
  end
end
```

- [ ] **Step 4: Migrate**

Run: `bin/rails db:migrate`
Expected: adds the column and rewrites `db/schema.rb` (the `lights` table gains `t.text "firmware_scenes"`).

- [ ] **Step 5: Add the model accessors**

In `app/models/light.rb`, add inside the class (after the `validates` lines):

```ruby
  serialize :firmware_scenes, coder: JSON, type: Array

  # Always present, even before discovery has written a list.
  def firmware_scenes = super || []
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/models/light_test.rb`
Expected: PASS (existing + 2 new).

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/light.rb test/models/light_test.rb
git commit -m "Persist per-light firmware_scenes (JSON text column)"
```

---

### Task 5: `GoveeSceneDiscoveryHandler`

**Files:**
- Create: `lib/govee_scene_discovery_handler.rb`
- Modify: `bin/ziwoas_collector` (register the handler)
- Test: `test/govee_scene_discovery_handler_test.rb`

**Interfaces:**
- Consumes: retained `gv2mqtt/select/+/config` messages; `Light.find_by(key:)`; `Light#firmware_scenes=` (Task 4).
- Produces: a handler implementing the `MqttRouter` contract (`#subscriptions`, `#matches?`, `#handle`). On a scene-`select` config it sets the matching light's `firmware_scenes` to the config's `options`. Non-scene selects (e.g. work-mode) and configs for unknown lights are ignored.

- [ ] **Step 1: Write the failing tests**

Create `test/govee_scene_discovery_handler_test.rb`:

```ruby
require "test_helper"
require "govee_scene_discovery_handler"
require "logger"
require "stringio"

class GoveeSceneDiscoveryHandlerTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    @log_io  = StringIO.new
    @handler = GoveeSceneDiscoveryHandler.new(logger: Logger.new(@log_io))
    @light   = Light.create!(name: "Decke", key: "14ABDB4844064B60")
  end

  def scene_config(overrides = {})
    JSON.generate({
      "name"          => "Mode/Scene",
      "unique_id"     => "gv2mqtt-14ABDB4844064B60-mode-scene",
      "command_topic" => "gv2mqtt/14ABDB4844064B60/set-mode-scene",
      "state_topic"   => "gv2mqtt/14ABDB4844064B60/notify-mode-scene",
      "options"       => [ "Forest", "Aurora", "Candy" ]
    }.merge(overrides))
  end

  test "subscriptions targets the select config topic" do
    assert_equal [ "gv2mqtt/select/+/config" ], @handler.subscriptions
  end

  test "matches select config topics only" do
    assert @handler.matches?("gv2mqtt/select/gv2mqtt-14ABDB4844064B60-mode-scene/config")
    refute @handler.matches?("gv2mqtt/light/14ABDB4844064B60/config")
    refute @handler.matches?("gv2mqtt/select/x/state")
  end

  test "stores the scene options on the matching light" do
    @handler.handle("gv2mqtt/select/gv2mqtt-14ABDB4844064B60-mode-scene/config", scene_config)
    assert_equal %w[Forest Aurora Candy], @light.reload.firmware_scenes
  end

  test "ignores a non-scene select (e.g. work mode)" do
    cfg = scene_config("unique_id" => "gv2mqtt-14ABDB4844064B60-workMode",
                       "command_topic" => "gv2mqtt/14ABDB4844064B60/set-work-mode",
                       "options" => [ "Low", "High" ])
    @handler.handle("gv2mqtt/select/gv2mqtt-14ABDB4844064B60-workMode/config", cfg)
    assert_equal [], @light.reload.firmware_scenes
  end

  test "ignores a config for an unknown light" do
    cfg = scene_config("command_topic" => "gv2mqtt/FFFFFFFFFFFFFFFF/set-mode-scene",
                       "unique_id" => "gv2mqtt-FFFFFFFFFFFFFFFF-mode-scene")
    assert_nothing_raised { @handler.handle("gv2mqtt/select/x/config", cfg) }
    assert_equal [], @light.reload.firmware_scenes
    assert_match(/no light/i, @log_io.string)
  end

  test "ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("gv2mqtt/select/x/config", "not-json{") }
    assert_match(/invalid json/i, @log_io.string)
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test TEST=test/govee_scene_discovery_handler_test.rb`
Expected: FAIL — `cannot load such file -- govee_scene_discovery_handler`.

- [ ] **Step 3: Implement the handler**

Create `lib/govee_scene_discovery_handler.rb`:

```ruby
require "json"

# Consumes govee2mqtt's retained scene-select discovery config
# (gv2mqtt/select/<unique_id>/config where unique_id ends with "-mode-scene")
# and stores the device's firmware scene names on the matching Light. The
# device id is parsed from the config's command_topic
# (gv2mqtt/<id>/set-mode-scene) and equals the Light#key set by
# GoveeDiscoveryHandler. Non-scene selects (e.g. work mode) are ignored.
class GoveeSceneDiscoveryHandler
  PREFIX = "gv2mqtt/select/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{PREFIX}+/config" ]

  def matches?(topic)
    topic.start_with?(PREFIX) && topic.end_with?("/config")
  end

  def handle(topic, payload)
    data = JSON.parse(payload)
    return unless data["unique_id"].to_s.end_with?("-mode-scene")

    key = device_id_from(data["command_topic"])
    return @logger.warn("GoveeSceneDiscoveryHandler: no usable command_topic on #{topic}") unless key

    light = Light.find_by(key: key)
    return @logger.warn("GoveeSceneDiscoveryHandler: no light for key #{key} on #{topic}") unless light

    light.update!(firmware_scenes: Array(data["options"]))
  rescue JSON::ParserError => e
    @logger.warn("GoveeSceneDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def device_id_from(command_topic)
    t = command_topic.to_s
    return nil unless t.start_with?("gv2mqtt/") && t.end_with?("/set-mode-scene")
    t.split("/")[1]
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/govee_scene_discovery_handler_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 5: Register the handler in the collector**

In `bin/ziwoas_collector`, add the require alongside the others (after line 10, `require "govee_discovery_handler"`):

```ruby
require "govee_scene_discovery_handler"
```

and add it to the handler list (after the `GoveeDiscoveryHandler` line, ~line 28):

```ruby
handlers << GoveeSceneDiscoveryHandler.new(logger: logger)
```

- [ ] **Step 6: Verify boot is clean**

Run: `bin/rails runner 'require "govee_scene_discovery_handler"; puts GoveeSceneDiscoveryHandler.new(logger: Logger.new(nil)).subscriptions.inspect'`
Expected: prints `["gv2mqtt/select/+/config"]` with no load error.

- [ ] **Step 7: Commit**

```bash
git add lib/govee_scene_discovery_handler.rb test/govee_scene_discovery_handler_test.rb bin/ziwoas_collector
git commit -m "Read Govee firmware scenes from gv2mqtt select discovery into lights.firmware_scenes"
```

---

### Task 6: Szenen tab view + scene preview helper

**Files:**
- Create: `app/helpers/lights_helper.rb`
- Test: `test/helpers/lights_helper_test.rb`
- Modify: `app/views/lights/show.html.erb` (replace only the `data-tab="scenes"` panel)
- Test: `test/controllers/lights_controller_test.rb` (extend)

**Interfaces:**
- Consumes: `LightMood::ALL` (Task 2), `@light.firmware_scenes` (Task 4), `scene_gradient` (this task). Stimulus actions `light-detail#mood` / `light-detail#scene` (wired in Task 7).
- Produces stable DOM hooks: mood buttons `[data-action="light-detail#mood"][data-light-detail-mood-param="<id>"]`; scene buttons `[data-action="light-detail#scene"][data-light-detail-scene-param="<name>"]`; both with class `.ld-scene`.

- [ ] **Step 1: Write the helper test**

Create `test/helpers/lights_helper_test.rb`:

```ruby
require "test_helper"

class LightsHelperTest < ActionView::TestCase
  test "scene_gradient is deterministic for a given name" do
    assert_equal scene_gradient("Forest"), scene_gradient("Forest")
  end

  test "scene_gradient differs for different names and is a linear-gradient" do
    assert scene_gradient("Forest").start_with?("linear-gradient")
    refute_equal scene_gradient("Forest"), scene_gradient("Aurora")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test TEST=test/helpers/lights_helper_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'scene_gradient'`.

- [ ] **Step 3: Implement the helper**

Create `app/helpers/lights_helper.rb`:

```ruby
module LightsHelper
  # govee2mqtt gives us only the scene NAME, not real colours, so derive a
  # stable two-stop gradient from the name for the preview swatch.
  def scene_gradient(name)
    sum = name.to_s.each_char.sum(&:ord)
    "linear-gradient(135deg, hsl(#{sum % 360} 70% 55%), hsl(#{(sum * 7) % 360} 65% 45%))"
  end
end
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `bin/rails test TEST=test/helpers/lights_helper_test.rb`
Expected: PASS.

- [ ] **Step 5: Replace the Szenen panel in the view**

In `app/views/lights/show.html.erb`, replace the existing scenes panel:

```erb
  <div class="ld-panel" data-light-detail-target="panel" data-tab="scenes" hidden>
    <div class="ld-card ld-soon">Szenen kommen in Phase 2.</div>
  </div>
```

with:

```erb
  <div class="ld-panel" data-light-detail-target="panel" data-tab="scenes" hidden>
    <div class="ld-card">
      <p class="ld-label">Stimmungen</p>
      <div class="ld-scenes">
        <% LightMood::ALL.each do |mood| %>
          <button class="ld-scene" data-action="light-detail#mood"
                  data-light-detail-mood-param="<%= mood.id %>">
            <span class="ld-scene-prev" style="background: <%= mood.gradient %>"></span>
            <span class="ld-scene-nm"><%= mood.emoji %> <%= mood.name %></span>
          </button>
        <% end %>
      </div>

      <% if @light.firmware_scenes.any? %>
        <p class="ld-label" style="margin-top: 16px;">Govee-Szenen</p>
        <div class="ld-scenes ld-scenes-scroll">
          <% @light.firmware_scenes.each do |scene| %>
            <button class="ld-scene" data-action="light-detail#scene"
                    data-light-detail-scene-param="<%= scene %>">
              <span class="ld-scene-prev" style="background: <%= scene_gradient(scene) %>"></span>
              <span class="ld-scene-nm"><%= scene %></span>
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
  </div>
```

- [ ] **Step 6: Extend the controller test**

Append inside `class LightsControllerTest` (before the final `end`) in `test/controllers/lights_controller_test.rb`:

```ruby
  test "scenes tab renders the curated Stimmungen" do
    get light_url(@light.key)
    assert_select "button[data-action='light-detail#mood'][data-light-detail-mood-param='reading']"
    assert_select "button[data-light-detail-mood-param='party']"
  end

  test "scenes tab renders the device firmware scenes when present" do
    @light.update!(firmware_scenes: %w[Forest Aurora])
    get light_url(@light.key)
    assert_select "button[data-action='light-detail#scene'][data-light-detail-scene-param='Forest']"
    assert_select "button[data-light-detail-scene-param='Aurora']"
  end

  test "scenes tab omits the Govee section when the light has no scenes" do
    @light.update!(firmware_scenes: [])
    get light_url(@light.key)
    assert_select "button[data-action='light-detail#scene']", count: 0
  end
```

- [ ] **Step 7: Run the controller tests to verify they pass**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb`
Expected: PASS (existing Phase-1 tests + 3 new).

- [ ] **Step 8: Commit**

```bash
git add app/helpers/lights_helper.rb test/helpers/lights_helper_test.rb app/views/lights/show.html.erb test/controllers/lights_controller_test.rb
git commit -m "Render Stimmungen + Govee firmware scenes in the Szenen tab"
```

---

### Task 7: `light_detail` controller — mood/scene actions

**Files:**
- Modify: `app/javascript/controllers/light_detail_controller.js`

**Interfaces:**
- Consumes: scene-tab DOM (Task 6); `POST /lights/:key/command` with `command=mood&mood=<id>` and `command=effect&effect=<name>`.
- Produces: `mood(event)` and `scene(event)` actions; both mark the tapped `.ld-scene` selected (client-only) and send the command via the existing `send()`.

- [ ] **Step 1: Add the actions**

In `app/javascript/controllers/light_detail_controller.js`, add after the `swatch`/`wheel`/`applyHex` block (before `// --- plumbing ---`):

```javascript
  // --- scenes & moods ---
  mood(event) {
    this.selectScene(event.currentTarget)
    this.send({ command: "mood", mood: event.params.mood })
  }

  scene(event) {
    this.selectScene(event.currentTarget)
    this.send({ command: "effect", effect: event.params.scene })
  }

  selectScene(btn) {
    this.element.querySelectorAll(".ld-scene.sel").forEach((b) => b.classList.remove("sel"))
    btn.classList.add("sel")
  }
```

- [ ] **Step 2: Verify it still boots / parses**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb`
Expected: PASS (importmap is checked on boot; a JS syntax error would surface).

- [ ] **Step 3: Manual check (stated, not automated)**

With `bin/dev` running and a scene-capable light, open `/lights/<key>` → Szenen tab: tapping a Stimmung sends `POST …/command` with `command=mood`; tapping a Govee scene sends `command=effect`; the tapped tile gets the `sel` outline and the others lose it. Note manual verification in the commit body.

- [ ] **Step 4: Commit**

```bash
git add app/javascript/controllers/light_detail_controller.js
git commit -m "Wire mood/scene taps on the lamp detail page (manually verified)"
```

---

### Task 8: Szenen-tab CSS

**Files:**
- Modify: `app/assets/stylesheets/application.css` (append; remove the now-stale `.ld-soon` rule)

**Interfaces:** Styles the classes from Task 6. No behaviour.

- [ ] **Step 1: Append the styles**

Add to the end of `app/assets/stylesheets/application.css`:

```css
/* ---- Szenen tab (Stimmungen + Govee scenes) ---- */
.ld-scenes { display: grid; grid-template-columns: 1fr 1fr; gap: 9px; }
.ld-scenes-scroll { max-height: 230px; overflow-y: auto; padding-right: 2px; }
.ld-scene { padding: 0; border: 1px solid var(--border); border-radius: 13px; overflow: hidden;
            background: var(--card); cursor: pointer; text-align: left; }
.ld-scene-prev { display: block; height: 46px; }
.ld-scene-nm { display: block; padding: 7px 9px; font-size: 12px; font-weight: 600; color: var(--text);
               white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ld-scene.sel { outline: var(--focus-ring); outline-offset: 1px; }
.ld-scene:focus-visible { outline: var(--focus-ring); outline-offset: 1px; }
```

- [ ] **Step 2: Remove the now-unused placeholder rule**

In `app/assets/stylesheets/application.css`, delete the line:

```css
.ld-soon { color: var(--muted); font-size: 14px; }
```

(the `.ld-soon` element was removed in Task 6.)

- [ ] **Step 3: Manual check (stated, not automated)**

Reload `/lights/<key>` → Szenen tab: Stimmungen show as a 2-column grid of gradient cards with emoji labels; if the device has scenes, a scrollable Govee-scene grid appears below; tapping outlines the selected card. Note manual verification in the commit body.

- [ ] **Step 4: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "Style the Szenen tab (Stimmungen + Govee scene grids)"
```

---

## Part B — Plüsch-Assets

### Task 9: `Light#plush_type` (SKU → asset family)

**Files:**
- Modify: `app/models/light.rb`
- Test: `test/models/light_test.rb`

**Interfaces:**
- Produces: `Light#plush_type -> "uplighter" | "floorlamp" | "sconce" | "ceiling" | "generic"`, mapped case-insensitively from `sku`; `generic` for unknown/blank. Used by the plush partial (Task 10).

- [ ] **Step 1: Write the failing tests**

Append inside `class LightTest` (before the final `end`) in `test/models/light_test.rb`:

```ruby
  test "plush_type maps known SKUs case-insensitively" do
    assert_equal "uplighter", Light.new(sku: "H60B0").plush_type
    assert_equal "floorlamp", Light.new(sku: "h607c").plush_type
    assert_equal "sconce",    Light.new(sku: "H6038").plush_type
    assert_equal "ceiling",   Light.new(sku: "H60A6").plush_type
  end

  test "plush_type falls back to generic for unknown or blank SKU" do
    assert_equal "generic", Light.new(sku: "H9999").plush_type
    assert_equal "generic", Light.new(sku: nil).plush_type
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bin/rails test TEST=test/models/light_test.rb -n "/plush_type/"`
Expected: FAIL — `undefined method 'plush_type'`.

- [ ] **Step 3: Implement the map**

In `app/models/light.rb`, add inside the class:

```ruby
  PLUSH_TYPES = {
    "H60B0" => "uplighter",
    "H607C" => "floorlamp",
    "H6038" => "sconce",
    "H60A6" => "ceiling"
  }.freeze

  def plush_type = PLUSH_TYPES.fetch(sku.to_s.upcase, "generic")
```

- [ ] **Step 4: Run them to verify they pass**

Run: `bin/rails test TEST=test/models/light_test.rb`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add app/models/light.rb test/models/light_test.rb
git commit -m "Map Light SKU to a plush asset family (generic fallback)"
```

---

### Task 10: Wire plush assets into the list tile and detail hero (CSS background-image, like the plug)

**Files:**
- Add: `app/assets/images/lamp_<type>_{on,off}.webp` (10 files)
- Modify: `app/views/switches/_light_card.html.erb`
- Modify: `app/views/lights/show.html.erb` (hero lamp class)
- Modify: `app/javascript/controllers/light_detail_controller.js` (hero lamp off-toggle)
- Modify: `app/assets/stylesheets/application.css`
- Test: `test/controllers/switches_controller_test.rb`, `test/controllers/lights_controller_test.rb`

**Interfaces:**
- Consumes: `Light#plush_type` (Task 9). Reuses the exact plug technique: an empty element whose plush image is a CSS `background-image`, swapped on/off by an `.off` class.
- Produces: a `plush-<type>` CSS class carried by the knob (list) and the hero lamp (detail); the lit/greyed swap is driven by `.off` on that same element. The list knob already gets `.off` from `lights_controller.js`; this task makes the detail controller toggle `.off` on the hero **lamp** element (it currently toggles `is-off` on the root — see note).

> **Note — unify the off-trigger:** the Phase-1 detail view renders `is-off` on `.ld-hero` while `light_detail_controller.js` toggles it on the **root** `.ld` element, so the hero never actually reacts to a live toggle (latent Phase-1 inconsistency). `is-off` styles nothing but the lamp. This task drops `is-off` and instead drives the lamp from an `.off` class on the `.ld-lamp` element itself — the same trigger the list knob uses — so one set of `.plush-<type>.off` rules serves both contexts.

- [ ] **Step 1: Ensure the 10 webp files exist (stage placeholders for local dev)**

The user supplies the final artwork. Tests/CI do not need these files (the suite asserts the CSS class, not an image), but `bin/dev` serving `application.css` does. If a target file is missing, stage a placeholder by copying an existing plush webp (the user overwrites the binary later — no code change needed):

```bash
cd "$(git rev-parse --show-toplevel)"
for t in uplighter floorlamp sconce ceiling generic; do
  for s in on off; do
    f="app/assets/images/lamp_${t}_${s}.webp"
    [ -f "$f" ] || cp "app/assets/images/switch_plush_${s}.webp" "$f"
  done
done
ls app/assets/images/lamp_*_*.webp | wc -l   # expect 10
```

- [ ] **Step 2: Add the per-type class to the list-tile knob**

In `app/views/switches/_light_card.html.erb`, change the knob button's class:

```erb
  <button class="sw-knob sw-lamp-knob<%= ' off' unless row.on? %>"
```

to:

```erb
  <button class="sw-knob sw-lamp-knob plush-<%= row.light.plush_type %><%= ' off' unless row.on? %>"
```

(leave the rest of the button — `data-action`, `data-lights-key-param`, `aria-label`, the empty body — unchanged; like `.sw-knob`, the image comes from CSS.)

- [ ] **Step 3: Add the per-type class to the detail hero lamp**

In `app/views/lights/show.html.erb`, change the hero lamp div:

```erb
    <div class="ld-lamp" data-light-detail-target="lamp"></div>
```

to:

```erb
    <div class="ld-lamp plush-<%= @light.plush_type %><%= ' off' unless @row.on? %>" data-light-detail-target="lamp"></div>
```

(The hero `<div class="ld-hero<%= ' is-off' unless @row.on? %>">` wrapper keeps its class for now; Step 5 stops styling the lamp off it. You may leave the `is-off` on `.ld-hero` — nothing references it after Step 5 — or drop it; do not add work either way.)

- [ ] **Step 4: Drive the hero lamp's off-state from the broadcast**

In `app/javascript/controllers/light_detail_controller.js`, inside `onBroadcast`, replace:

```javascript
    this.element.classList.toggle("is-off", light.on === false)
```

with:

```javascript
    if (this.hasLampTarget) this.lampTarget.classList.toggle("off", light.on === false)
```

(The `lamp` target already exists in `static targets` and is otherwise unused.)

- [ ] **Step 5: Update the CSS (knob, hero lamp, per-type images)**

In `app/assets/stylesheets/application.css`:

(a) Replace the hero-lamp rules:

```css
.ld-lamp { width: 58px; height: 58px; border-radius: 50%; flex-shrink: 0;
           background: radial-gradient(circle at 50% 38%, var(--accent-tint) 0%, var(--accent-tint-2) 45%, var(--accent) 100%);
           box-shadow: var(--glow-accent); }
.ld-hero.is-off .ld-lamp { background: var(--surface-sunk); box-shadow: none; filter: grayscale(.4); }
```

with:

```css
.ld-lamp { width: 64px; height: 64px; flex-shrink: 0; border-radius: var(--radius-lg);
           background-size: contain; background-position: center; background-repeat: no-repeat;
           box-shadow: var(--glow-accent); }
.ld-lamp.off { box-shadow: none; filter: grayscale(.4); }
```

(b) Replace the plush-knob placeholder rules:

```css
/* plush placeholder: a glowing knob, tinted via CSS (real assets in Phase 4) */
.sw-lamp-knob { border-color: var(--accent);
                background: radial-gradient(circle at 50% 38%, var(--accent-tint), var(--accent-tint-2) 55%, var(--accent));
                background-image: none; box-shadow: var(--glow-accent); }
.sw-lamp-knob.off { border-color: var(--offline);
                    background: var(--surface-sunk); box-shadow: none; filter: grayscale(.35); }
```

with (the `plush-<type>` rules set only the image, so the same class works on the 88px knob — which inherits size/position/repeat from `.sw-knob` — and the hero lamp):

```css
/* plush lamp: per-SKU artwork via background-image (same technique as .sw-knob) */
.sw-lamp-knob { border-color: var(--accent); background-color: transparent; box-shadow: var(--glow-accent); }
.sw-lamp-knob.off { border-color: var(--offline); background-color: var(--surface-sunk);
                    box-shadow: none; filter: grayscale(.35); }
.plush-uplighter { background-image: url(lamp_uplighter_on.webp); }
.plush-uplighter.off { background-image: url(lamp_uplighter_off.webp); }
.plush-floorlamp { background-image: url(lamp_floorlamp_on.webp); }
.plush-floorlamp.off { background-image: url(lamp_floorlamp_off.webp); }
.plush-sconce { background-image: url(lamp_sconce_on.webp); }
.plush-sconce.off { background-image: url(lamp_sconce_off.webp); }
.plush-ceiling { background-image: url(lamp_ceiling_on.webp); }
.plush-ceiling.off { background-image: url(lamp_ceiling_off.webp); }
.plush-generic { background-image: url(lamp_generic_on.webp); }
.plush-generic.off { background-image: url(lamp_generic_off.webp); }
```

- [ ] **Step 6: Update the render tests (assert the plush class, not an image src)**

In `test/controllers/switches_controller_test.rb`, change the setup light to a known SKU. Replace the `setup` block's light creation line:

```ruby
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe")
```

with:

```ruby
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe", sku: "H607C")
```

and append inside the class (before the final `end`):

```ruby
  test "lamp tile knob carries the per-SKU plush class" do
    get switches_url
    assert_select "button.sw-lamp-knob.plush-floorlamp"
  end
```

In `test/controllers/lights_controller_test.rb`, append inside `class LightsControllerTest` (before the final `end`):

```ruby
  test "detail hero lamp carries the per-SKU plush class" do
    @light.update!(sku: "H60A6")
    get light_url(@light.key)
    assert_select ".ld-lamp.plush-ceiling"
  end
```

- [ ] **Step 7: Run the affected tests**

Run: `bin/rails test TEST=test/controllers/switches_controller_test.rb TEST=test/controllers/lights_controller_test.rb`
Expected: PASS (no webp dependency — the assertions check the CSS class the SKU maps to).

- [ ] **Step 8: Manual check (stated, not automated)**

Reload Schalten: each lamp shows its plush figure in the right-hand knob (lit when on, greyed when off). Open a lamp → the hero shows the larger plush; toggling power swaps lit/greyed live. Confirm the `lamp_<type>` matches the device (H60B0→uplighter, H607C→floorlamp, H6038→sconce, H60A6→ceiling, else generic). Note manual verification in the commit body.

- [ ] **Step 9: Commit**

```bash
git add app/assets/images/lamp_*_*.webp app/views/switches/_light_card.html.erb app/views/lights/show.html.erb app/javascript/controllers/light_detail_controller.js app/assets/stylesheets/application.css test/controllers/switches_controller_test.rb test/controllers/lights_controller_test.rb
git commit -m "Wire per-SKU plush assets into the lamp tile and detail hero (CSS background-image)"
```

---

### Task 11: Full check & cleanup

**Files:** none (verification).

- [ ] **Step 1: Run the full suite**

Ensure the dev stack is stopped (SQLite lock), then run:

Run: `bin/ci`
Expected: Rubocop clean, Brakeman clean, all Rails tests pass (existing + every test added in Tasks 1–10).

- [ ] **Step 2: Manual end-to-end check (stated)**

`bin/dev`, then:
- Schalten: plush knobs render per device, lit/greyed track power; tapping a knob toggles.
- A lamp detail page → Szenen tab: Stimmungen apply (a warm one like Lesen, an RGB one like Party); on a scene-capable device the Govee-scene grid appears and a scene applies. Confirm broadcasts clear the `pending` state.

- [ ] **Step 3: Commit any rubocop autofixes**

If `bin/ci` reported offences, fix them and:

```bash
git add -A
git commit -m "Fix rubocop offences in lamp UI Phase 2"
```

---

## Self-Review

**Spec coverage (Phase 2 + the user-requested plush wiring):**
- Szenen-Tab = own Stimmungen above + device Govee scenes below → Tasks 2, 6 (matches `scenes-and-tile.html`). ✓
- Stimmungen composed from existing colour/temp/brightness primitives, work on any lamp → `LightMood` (Task 2) + `mood` command (Task 3). ✓
- Read Govee firmware scenes from gv2mqtt `select` discovery + persist → Tasks 4, 5 (verified topic/payload from vendored source). ✓
- Activate a scene via `effect` → `GoveeCommander.set_effect` (Task 1) + `effect` command (Task 3) + `scene` action (Task 7). ✓
- Per-type plush, modelled per SKU, on/off, CSS-tinted glow; generic fallback → Tasks 9, 10. ✓
- Backend item "status broadcast of active scene" → explicitly deferred (see "What is NOT in Phase 2"). Zones/segments → Phase 3.

**Placeholder scan:** every code step shows complete code; no TBD/TODO. The staged webp copies (Task 10 Step 1) are a real, runnable fallback for local dev before final art lands — flagged, not silent. Tests/CI do not depend on them.

**Type/selector consistency:**
- Command values `effect`/`mood` are produced by the JS (Task 7) and consumed by the controller `case` (Task 3) verbatim.
- Stimulus params are namespaced: `data-light-detail-mood-param` / `data-light-detail-scene-param` (Task 6) ↔ `event.params.mood` / `event.params.scene` (Task 7). (Phase-1 critical-bug guard honoured.)
- `LightMood::Mood` fields used in the view (`id, name, emoji, gradient`) and controller (`brightness, color, color_temp_k`) all exist in the `Data.define` (Task 2).
- `firmware_scenes` is written by the discovery handler (Task 5) and read by the view (Task 6); the device-id parse in Task 5 keys off the same `<id>` `GoveeDiscoveryHandler` already stores as `Light#key`.
- Plush uses the plug's CSS-`background-image` technique: a `plush-<type>` class on the element with `.off` swapping to the off image. Both contexts use `.off` on the same element — the list knob already gets it from `lights_controller.js`; Task 10 Step 4 makes `light_detail_controller.js` toggle `.off` on the hero `.ld-lamp` (replacing the dead `is-off`-on-root path).
- `plush_type` values (`uplighter/floorlamp/sconce/ceiling/generic`, Task 9) match the CSS class names and the `lamp_<type>_{on,off}.webp` filenames (Task 10).

**Token consistency:** new CSS (Tasks 8, 10) uses `--border`, `--card`, `--text`, `--accent`, `--offline`, `--surface-sunk`, `--radius-lg`, `--radius-md` (13px scene radius is a one-off, kept literal like Phase-1 one-offs), `--focus-ring`, `--glow-accent` — all defined in `:root`.

## Follow-up plans (not this plan)

- **Phase 3 — Zonen (Uplighter):** segment-entity discovery + zone model, zone cards, max-2 rule with protected main zone + undo toast, adaptive detail page (zones tab default, no master slider).
- **Active-scene reflection:** capture the live scene (from the light state's `effect` field or `gv2mqtt/<id>/notify-mode-scene`) into `LightState`, broadcast it, and persist the selected-scene highlight across reloads.
- **Real plush artwork:** the user replaces the staged placeholder webps with final per-SKU art (no code change).
