# Govee Lamp UI — Phase 3: Zonen-Lampen (Uplighter) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give multi-zone lamps (the Uplighter H60B0) a `Zonen` tab on the detail page — one on/off card per physical zone, the main zone protected, a "max. 2 zones" auto-off rule with toast/undo — while colour/white/brightness/scenes stay whole-lamp; and fix the Phase-2 scene source so the scene list actually populates.

**Architecture:** Additive on the Phase-1/2 command + status + discovery pipeline. Zones are **HA `switch` toggles** (verified at the real lamp — see Grounding), so: a new `GoveeZoneDiscoveryHandler` reads the per-zone `switch` discovery configs and stores the zone keys on `lights.zones`; a new `GoveeZoneStateHandler` reflects each zone's on/off into `light_states.zone_states` and broadcasts it; `GoveeCommander.set_zone` publishes a raw `ON`/`OFF` to the zone command topic. The detail page renders a `Zonen` tab for any lamp with ≥2 zones (default tab), reusing the existing Weiß/Farbe/Szenen panels unchanged (they act on the whole device). The "max. 2" rule + toast/undo live **client-side** (optimistic, like the rest of the UI). Power for zone lamps goes through the `powerSwitch` toggle (the main-light `state:ON` did not power the Uplighter). Separately, `GoveeDiscoveryHandler` now reads scenes from the main-light `effect_list` and the never-firing `GoveeSceneDiscoveryHandler` is removed.

**Tech Stack:** Rails 8.1, Hotwire/Stimulus, ActionCable (DashboardChannel), Propshaft assets, Minitest + fixtures, plain CSS in `app/assets/stylesheets/application.css`, MQTT via `GoveeCommander` / `MqttRouter`.

## Grounding (verified at the real Uplighter H60B0 `14ABDB4844064B60`, 2026-06-26)

Robert watched the physical lamp while it was driven over MQTT. Full notes: memory `uplighter-h60b0-control-facts`; spec section "Phase-3 Realitäts-Update".

- **Zones are HA `switch` toggles, on/off ONLY** (no per-zone colour/brightness). Discovery config at `gv2mqtt/switch/gv2mqtt-<id>-<instance>/config`; command at **`gv2mqtt/switch/<id>/command/<instance>`** with a **raw string payload `ON`/`OFF`** (not JSON); state at `gv2mqtt/switch/<id>/<instance>/state` (`ON`/`OFF`). The `<id>` equals `Light#key`.
- Uplighter zone instances: `bottomLightToggle` (Unten/Leselicht = **Haupt**), `sideLightToggle` (Seite), `rippleLightToggle` (Welle). Non-zone toggles on the same device: `powerSwitch`, `dreamViewToggle` — these are NOT lighting zones and must be excluded from the zone list.
- **Power = `powerSwitch`**: publishing `{"state":"ON"}` to `gv2mqtt/light/<id>/command` did NOT power the lamp; `ON` to `gv2mqtt/switch/<id>/command/powerSwitch` did. So zone lamps power via `powerSwitch`. Colour/brightness/temp/effect still go to the main light command (they carry `state:ON` and work once powered).
- **Colour is whole-lamp**: main-light RGB colours Welle + Seite together (one channel); `color_temp` (white) hits only Leselicht; brightness is global. There is no usable per-zone colour (segment entities `…/command/0..14` return API `200 success` but render nothing outside DIY mode).
- **Scenes live in `effect_list`** on the main-light discovery config (`gv2mqtt/light/gv2mqtt-<id>/config`), ~120 entries incl. a leading `""`. There is **no** `gv2mqtt/select/…` entity — the Phase-2 `GoveeSceneDiscoveryHandler` never receives anything, so `firmware_scenes` stays empty until this fix.
- **govee2mqtt does not mirror Govee-app changes in real time** (only on a slow poll). Our own commands reflect immediately → keep the existing optimistic-send + broadcast-reconcile pattern; do not promise live mirroring of external changes.

## Global Constraints

- Spec: [docs/superpowers/specs/2026-06-26-govee-lamp-ui-design.md](../specs/2026-06-26-govee-lamp-ui-design.md) — sections "Detailseite (Variante B)", "Max. 2 Zonen-Regel", and "Phase-3 Realitäts-Update" (the latter governs where it differs from the older text). Visual reference: [uplighter-v2.html](../specs/2026-06-26-govee-lamp-ui-mockups/uplighter-v2.html) — **note:** that mockup shows per-zone sliders + swatches, which the hardware does NOT support; take from it only the zone-card layout, the "Haupt" badge, the dimmed auto-off zone, and the toast-with-Rückgängig. The colour/white controls stay whole-lamp.
- German UI copy throughout.
- Lights are addressed by `:key`, never `:id` (`Light#to_param` returns `key`). Commands go to `POST /lights/:light_key/command` (`light_command_url`).
- Phase 3 ADDS one command value: `zone` (params `zone` = toggle instance key, `on` = bool). It also CHANGES the `turn` command to route zone lamps through `powerSwitch`. Existing `brightness|color|color_temp|effect|mood` are unchanged and still whole-lamp.
- **Zone command security:** the controller MUST reject a `zone` whose key is not in that light's stored `zones` list (never publish an arbitrary instance name to the switch topic). `powerSwitch` is only ever sent by the server's own `turn` branch, never from a user-supplied `zone` param.
- **Raw vs JSON payloads:** zone/`powerSwitch` commands are **raw strings** `ON`/`OFF`. The existing light commands stay JSON. Keep both paths in `GoveeCommander`; do not JSON-encode the switch payload.
- **Stimulus action params MUST be namespaced by the controller identifier:** for `data-controller="light-detail"`, write `data-light-detail-<name>-param="…"` and read `event.params.<name>`. (A non-namespaced `data-<name>-param` yields `undefined` — shipped-and-caught bug in Phase 1. Do not repeat it.)
- **A light is a "zone lamp" when it has ≥2 stored zones.** `default_tab` for a zone lamp is `"zones"`; otherwise the existing Phase-1 logic. Simple lamps render exactly as today (no Zonen tab).
- **ZONE_META is the single source of zone labels/roles** (German). `lights.zones` stores only the ordered toggle-instance keys; labels/roles are derived at render so copy can change without re-discovery. Only instances present in `ZONE_META` are treated as zones.
- **"max. 2 zones" is per-SKU and Uplighter-specific** (`H60B0` → 2; everything else → no limit). The rule is client-side and optimistic: turning on a side zone when the limit is already reached auto-turns-off the **last-activated side zone** (never the main zone), with a toast offering **Rückgängig**. Whether the hardware itself enforces the limit is unverified — implement the documented UX; note any observed double-toggle during the manual smoke check.
- Design tokens (defined in `:root`, Phase-1 Task 0): radii `--radius-sm/md/lg/pill`, `--accent-tint`/`--accent-tint-2`/`--accent-ink`, `--accent-bg`, `--surface-sunk`, `--surface-hover`, `--danger`, `--online`, `--offline`, `--focus-ring`, `--glow-accent`. New CSS consumes tokens (one-off radii / multi-stop gradients may stay literal, matching Phase 1/2).
- Run the full check with `bin/ci` before declaring done; it must run with the dev stack **stopped** (SQLite lock). Individual tests: `bin/rails test TEST=path -n test_name`.
- JS and CSS have no unit-test harness here. For those steps "verify" = render-assert markup/data-attributes in a controller test where possible, plus a stated manual check. Do not claim JS/CSS behaviour is tested when it is only manually checked.

## What is NOT in Phase 3 (explicit deferrals)

- **Per-zone colour / brightness / segments** — not possible over govee2mqtt for this hardware (verified). Out of scope permanently; colour/white/brightness remain whole-lamp.
- **Live reflection of Govee-app changes** — govee2mqtt does not push these promptly; the UI stays optimistic for our own commands and tolerates external drift until the next poll.
- **Active-scene/active-mood persistence** — still deferred from Phase 2 (selection highlight is client-only).
- **Other multi-zone lamps' bespoke tuning** — the zone mechanism is generic (H607C `base`/`pillar`, sconce `left`/`right` are in `ZONE_META` so they get a Zonen tab too), but only the Uplighter is hands-on-verified and gets a `max_active_zones`. Verifying the others is a later follow-up.

## File Structure

- Modify `lib/govee_commander.rb` — add `SWITCH_COMMAND_TOPIC`, `set_zone`, `publish_raw`.
- Modify `test/govee_commander_test.rb` — `set_zone` raw-payload + topic test.
- Create `db/migrate/<ts>_add_zones_to_lights.rb` — `lights.zones` text column.
- Create `db/migrate/<ts>_add_zone_states_to_light_states.rb` — `light_states.zone_states` text column.
- Modify `db/schema.rb` (regenerated by the migrations).
- Modify `app/models/light.rb` — serialize `zones`; `ZONE_META`, `MAX_ACTIVE_ZONES`; `zones` default, `zone_lamp?`, `max_active_zones`.
- Modify `test/models/light_test.rb`.
- Modify `app/models/light_state.rb` — serialize `zone_states`; `record_zone_state`.
- Modify `test/models/light_state_test.rb` (create if absent).
- Create `lib/govee_zone_discovery_handler.rb` — switch config → `lights.zones`.
- Create `test/govee_zone_discovery_handler_test.rb`.
- Create `lib/govee_zone_state_handler.rb` — switch toggle state → `zone_states` + broadcast.
- Create `test/govee_zone_state_handler_test.rb`.
- Modify `lib/govee_discovery_handler.rb` — read `effect_list` → `firmware_scenes`.
- Modify `test/govee_discovery_handler_test.rb` — effect_list assertion.
- Delete `lib/govee_scene_discovery_handler.rb` and `test/govee_scene_discovery_handler_test.rb` (replaced).
- Modify `bin/ziwoas_collector` — register the two new handlers; drop the scene handler.
- Modify `app/models/light_row.rb` — `zone_lamp?`, `zones` presenter, `default_tab`.
- Modify `test/models/light_row_test.rb` (create if absent).
- Modify `app/controllers/light_switches_controller.rb` — `zone` command + `turn` → `powerSwitch` for zone lamps.
- Modify `test/controllers/light_switches_controller_test.rb`.
- Modify `app/views/lights/show.html.erb` — Zonen tab + panel + zone cards + toast; whole-lamp colour label tweak for zone lamps; `maxZones` value.
- Modify `app/javascript/controllers/light_detail_controller.js` — `zone` action, max-2 + toast/undo, broadcast `zones`.
- Modify `app/assets/stylesheets/application.css` — zone cards, toggles, main highlight, toast.
- Modify `test/controllers/lights_controller_test.rb` — zone-tab render assertions.

---

### Task 1: `GoveeCommander.set_zone` (raw ON/OFF to the switch topic)

**Files:**
- Modify: `lib/govee_commander.rb`
- Test: `test/govee_commander_test.rb`

**Interfaces:**
- Consumes: existing `publish` connection/factory pattern (host/port from `mqtt_config`).
- Produces: `GoveeCommander.set_zone(light, zone:, on:, mqtt_config:, mqtt_factory: nil)` → publishes raw `"ON"`/`"OFF"` to `gv2mqtt/switch/<light.key>/command/<zone>`. Used by `LightSwitchesController` (Task 8).

- [ ] **Step 1: Write the failing test**

In `test/govee_commander_test.rb`, add (match the existing fake-client style — find how other tests capture published topic/payload and reuse it):

```ruby
test "set_zone publishes a raw ON to the per-zone switch command topic" do
  published = capture_publish do |factory|
    GoveeCommander.set_zone(light, zone: "rippleLightToggle", on: true,
                            mqtt_config: mqtt_config, mqtt_factory: factory)
  end
  assert_equal "gv2mqtt/switch/ABC123/command/rippleLightToggle", published[:topic]
  assert_equal "ON", published[:payload]
end

test "set_zone publishes a raw OFF (not JSON) when off" do
  published = capture_publish do |factory|
    GoveeCommander.set_zone(light, zone: "bottomLightToggle", on: false,
                            mqtt_config: mqtt_config, mqtt_factory: factory)
  end
  assert_equal "gv2mqtt/switch/ABC123/command/bottomLightToggle", published[:topic]
  assert_equal "OFF", published[:payload]
end
```

If `test/govee_commander_test.rb` has no `capture_publish`/`light`/`mqtt_config` helpers, mirror exactly the setup the existing `set_effect`/`turn` tests use (a stub `light` with `key: "ABC123"`, a fake MQTT client recording `(topic, payload)`), and assert the same fields. The key assertions: topic is the switch command topic and payload is the bare string `"ON"`/`"OFF"`, **not** `"{\"state\":...}"`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test TEST=test/govee_commander_test.rb -n /set_zone/`
Expected: FAIL — `NoMethodError: undefined method 'set_zone'`.

- [ ] **Step 3: Implement**

In `lib/govee_commander.rb`, add the topic constant near `COMMAND_TOPIC`:

```ruby
  SWITCH_COMMAND_TOPIC = "gv2mqtt/switch/%s/command/%s"
```

Add the method (next to `set_effect`):

```ruby
  # Zone/power toggles are HA switch entities: raw "ON"/"OFF" payloads on a
  # per-instance command topic, NOT the JSON light command. `zone` is a toggle
  # instance key (e.g. "rippleLightToggle", "powerSwitch").
  def self.set_zone(light, zone:, on:, mqtt_config:, mqtt_factory: nil)
    publish_raw(format(SWITCH_COMMAND_TOPIC, light.key, zone), (on ? "ON" : "OFF"),
                light:, mqtt_config:, mqtt_factory:)
  end
```

Refactor the connect/publish/rescue/disconnect plumbing out of `publish` into a shared `publish_raw(topic, payload, light:, mqtt_config:, mqtt_factory:)`, then make `publish` call it with the JSON-encoded payload and the device command topic. Concretely:

```ruby
  def self.publish(light, payload, mqtt_config:, mqtt_factory: nil)
    publish_raw(format(COMMAND_TOPIC, light.key), JSON.generate(payload),
                light:, mqtt_config:, mqtt_factory:)
  end

  def self.publish_raw(topic, payload, light:, mqtt_config:, mqtt_factory: nil)
    factory = mqtt_factory || -> { MQTT::Client.new(host: mqtt_config.host, port: mqtt_config.port) }
    client  = factory.call
    begin
      client.connect
      client.publish(topic, payload)
    rescue StandardError => e
      raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bin/rails test TEST=test/govee_commander_test.rb`
Expected: PASS (all existing GoveeCommander tests + the two new ones).

- [ ] **Step 5: Commit**

```bash
git add lib/govee_commander.rb test/govee_commander_test.rb
git commit -m "feat(govee): GoveeCommander.set_zone publishes raw ON/OFF to switch topic"
```

---

### Task 2: `Light` zone model (zones column, ZONE_META, helpers)

**Files:**
- Create: `db/migrate/<ts>_add_zones_to_lights.rb`
- Modify: `app/models/light.rb`, `db/schema.rb`
- Test: `test/models/light_test.rb`

**Interfaces:**
- Produces: `Light#zones` → `Array<String>` (ordered toggle-instance keys, default `[]`); `Light::ZONE_META` (Hash key→`{label:, role:}`); `Light#zone_lamp?` (≥2 zones); `Light#max_active_zones` (Integer or `nil`). Consumed by `GoveeZoneDiscoveryHandler` (Task 3), `LightRow` (Task 7), controller (Task 8), view (Task 9).

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration add_zones_to_lights zones:text`
Then edit the generated file to read exactly:

```ruby
class AddZonesToLights < ActiveRecord::Migration[8.1]
  def change
    add_column :lights, :zones, :text
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate`
Expected: `db/schema.rb` gains `t.text "zones"` on `lights`.

- [ ] **Step 3: Write the failing test**

In `test/models/light_test.rb` add:

```ruby
test "zones defaults to an empty array" do
  assert_equal [], Light.new.zones
end

test "zones round-trips a JSON array of toggle keys" do
  l = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
  assert_equal %w[bottomLightToggle rippleLightToggle], l.reload.zones
end

test "zone_lamp? is true only with two or more zones" do
  assert_not Light.new(zones: %w[bottomLightToggle]).zone_lamp?
  assert     Light.new(zones: %w[bottomLightToggle sideLightToggle]).zone_lamp?
end

test "ZONE_META labels the known uplighter toggles with a main role" do
  assert_equal "Leselicht", Light::ZONE_META["bottomLightToggle"][:label]
  assert_equal "main",      Light::ZONE_META["bottomLightToggle"][:role]
  assert_equal "side",      Light::ZONE_META["rippleLightToggle"][:role]
end

test "max_active_zones is 2 for the H60B0 uplighter and nil otherwise" do
  assert_equal 2,   Light.new(sku: "H60B0").max_active_zones
  assert_nil        Light.new(sku: "H607C").max_active_zones
end
```

- [ ] **Step 4: Run to verify it fails**

Run: `bin/rails test TEST=test/models/light_test.rb -n /zone/`
Expected: FAIL (`zones` not serialized / `ZONE_META` undefined).

- [ ] **Step 5: Implement**

In `app/models/light.rb` add below the existing `firmware_scenes` serialize:

```ruby
  serialize :zones, coder: JSON, type: Array

  # Toggle instance key → display label + role. Single source of zone copy;
  # `lights.zones` stores only the keys. Only listed instances count as zones
  # (powerSwitch / dreamViewToggle / gradientToggle are control toggles, not zones).
  ZONE_META = {
    "bottomLightToggle" => { label: "Leselicht", role: "main" },
    "rippleLightToggle" => { label: "Welle",     role: "side" },
    "sideLightToggle"   => { label: "Seite",     role: "side" },
    "baseLightToggle"   => { label: "Sockel",    role: "main" },
    "pillarLightToggle" => { label: "Säule",     role: "side" },
    "leftLightToggle"   => { label: "Links",     role: "side" },
    "rightLightToggle"  => { label: "Rechts",    role: "side" }
  }.freeze

  # Hardware limit: at most N zones lit at once (Uplighter). nil = no limit.
  MAX_ACTIVE_ZONES = { "H60B0" => 2 }.freeze
```

Add the readers/predicates (near `plush_type`):

```ruby
  def zones = super || []
  def zone_lamp? = zones.size >= 2
  def max_active_zones = MAX_ACTIVE_ZONES[sku.to_s.upcase]
```

- [ ] **Step 6: Run to verify it passes**

Run: `bin/rails test TEST=test/models/light_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/models/light.rb db/migrate db/schema.rb test/models/light_test.rb
git commit -m "feat(lights): zones column + ZONE_META + zone_lamp?/max_active_zones"
```

---

### Task 3: `GoveeZoneDiscoveryHandler` (switch configs → `lights.zones`)

**Files:**
- Create: `lib/govee_zone_discovery_handler.rb`
- Modify: `bin/ziwoas_collector`
- Test: `test/govee_zone_discovery_handler_test.rb`

**Interfaces:**
- Consumes: govee2mqtt switch discovery configs on `gv2mqtt/switch/+/config`; `Light` (find_or_initialize by key); `Light::ZONE_META`.
- Produces: upserts the ordered `zones` key list on the matching `Light`. Registered in `bin/ziwoas_collector`.

- [ ] **Step 1: Write the failing test**

Create `test/govee_zone_discovery_handler_test.rb` (mirror `test/govee_discovery_handler_test.rb` structure — `Light.delete_all` setup, StringIO logger):

```ruby
require "test_helper"
require "govee_zone_discovery_handler"
require "logger"
require "stringio"

class GoveeZoneDiscoveryHandlerTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    @log_io  = StringIO.new
    @handler = GoveeZoneDiscoveryHandler.new(logger: Logger.new(@log_io))
  end

  def cfg(instance)
    JSON.generate({
      "unique_id"     => "gv2mqtt-14ABDB4844064B60-#{instance}",
      "command_topic" => "gv2mqtt/switch/14ABDB4844064B60/command/#{instance}",
      "state_topic"   => "gv2mqtt/switch/14ABDB4844064B60/#{instance}/state",
      "device"        => { "name" => "Uplighter Floor Lamp", "model" => "H60B0" }
    })
  end

  test "subscribes to the switch discovery config topic" do
    assert_equal [ "gv2mqtt/switch/+/config" ], @handler.subscriptions
  end

  test "matches only switch config topics" do
    assert @handler.matches?("gv2mqtt/switch/gv2mqtt-x-rippleLightToggle/config")
    refute @handler.matches?("gv2mqtt/switch/14ABDB4844064B60/rippleLightToggle/state")
  end

  test "stores known zone toggles on the light, keyed by device id" do
    @handler.handle("gv2mqtt/switch/x/config", cfg("bottomLightToggle"))
    @handler.handle("gv2mqtt/switch/x/config", cfg("rippleLightToggle"))
    light = Light.find_by(key: "14ABDB4844064B60")
    assert_not_nil light
    assert_equal %w[bottomLightToggle rippleLightToggle], light.zones
  end

  test "ignores control toggles that are not lighting zones" do
    @handler.handle("gv2mqtt/switch/x/config", cfg("powerSwitch"))
    @handler.handle("gv2mqtt/switch/x/config", cfg("dreamViewToggle"))
    assert_nil Light.find_by(key: "14ABDB4844064B60")
  end

  test "does not duplicate a zone on re-discovery" do
    2.times { @handler.handle("gv2mqtt/switch/x/config", cfg("sideLightToggle")) }
    assert_equal %w[sideLightToggle], Light.find_by(key: "14ABDB4844064B60").zones
  end

  test "creates a placeholder-named light if it does not exist yet" do
    @handler.handle("gv2mqtt/switch/x/config", cfg("bottomLightToggle"))
    light = Light.find_by(key: "14ABDB4844064B60")
    assert_equal "14ABDB4844064B60", light.name # adopted later by GoveeDiscoveryHandler
  end

  test "ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("gv2mqtt/switch/x/config", "nope{") }
    assert_match(/invalid json/i, @log_io.string)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test TEST=test/govee_zone_discovery_handler_test.rb`
Expected: FAIL — `cannot load such file -- govee_zone_discovery_handler`.

- [ ] **Step 3: Implement**

Create `lib/govee_zone_discovery_handler.rb`:

```ruby
require "json"

# Consumes govee2mqtt's per-zone HA `switch` discovery configs
# (gv2mqtt/switch/<unique_id>/config) and stores the ordered list of *lighting*
# zone toggle keys on the matching Light. Only instances present in
# Light::ZONE_META are zones; control toggles (powerSwitch, dreamViewToggle,
# gradientToggle) are ignored. The device id is parsed from the command_topic
# (gv2mqtt/switch/<id>/command/<instance>) and equals Light#key. Never deletes;
# creates a placeholder-named Light if discovery order beats the light config.
class GoveeZoneDiscoveryHandler
  PREFIX = "gv2mqtt/switch/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{PREFIX}+/config" ]

  def matches?(topic)
    topic.start_with?(PREFIX) && topic.end_with?("/config")
  end

  def handle(topic, payload)
    data = JSON.parse(payload)
    key, instance = parse(data["command_topic"])
    return unless key && instance
    return unless Light::ZONE_META.key?(instance)

    light = Light.find_or_initialize_by(key: key)
    light.name = key if light.new_record?
    light.zones = (light.zones + [ instance ]).uniq
    light.save!
  rescue JSON::ParserError => e
    @logger.warn("GoveeZoneDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  # "gv2mqtt/switch/<id>/command/<instance>" -> ["<id>", "<instance>"]
  def parse(command_topic)
    t = command_topic.to_s.split("/")
    return [ nil, nil ] unless t.length == 5 && t[0] == "gv2mqtt" && t[1] == "switch" && t[3] == "command"
    [ t[2], t[4] ]
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test TEST=test/govee_zone_discovery_handler_test.rb`
Expected: PASS.

- [ ] **Step 5: Register in the collector**

In `bin/ziwoas_collector`, add the require near the other govee requires:

```ruby
require "govee_zone_discovery_handler"
```

and register it after `GoveeDiscoveryHandler`:

```ruby
handlers << GoveeZoneDiscoveryHandler.new(logger: logger)
```

- [ ] **Step 6: Commit**

```bash
git add lib/govee_zone_discovery_handler.rb test/govee_zone_discovery_handler_test.rb bin/ziwoas_collector
git commit -m "feat(govee): discover zone toggles into lights.zones"
```

---

### Task 4: Scene source fix — `effect_list` → `firmware_scenes`; remove the dead handler

**Files:**
- Modify: `lib/govee_discovery_handler.rb`, `test/govee_discovery_handler_test.rb`
- Delete: `lib/govee_scene_discovery_handler.rb`, `test/govee_scene_discovery_handler_test.rb`
- Modify: `bin/ziwoas_collector`

**Interfaces:**
- Consumes: the main-light discovery config's `effect_list` (Array of scene-name strings, includes a leading `""`).
- Produces: `Light#firmware_scenes` populated from `effect_list` (empty string filtered). Removes the never-firing select-based handler.

- [ ] **Step 1: Write the failing test**

In `test/govee_discovery_handler_test.rb`, extend the `config` helper isn't required — add a test that passes `effect_list` explicitly:

```ruby
test "stores firmware_scenes from effect_list, dropping the blank entry" do
  @handler.handle("gv2mqtt/light/x/config",
    config("effect_list" => [ "", "Sunset", "Ocean", "Party" ]))
  light = Light.find_by(key: "14ABDB4844064B60")
  assert_equal %w[Sunset Ocean Party], light.firmware_scenes
end

test "leaves firmware_scenes empty when effect_list is absent" do
  @handler.handle("gv2mqtt/light/x/config", config)
  assert_equal [], Light.find_by(key: "14ABDB4844064B60").firmware_scenes
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test TEST=test/govee_discovery_handler_test.rb -n /firmware_scenes/`
Expected: FAIL — `firmware_scenes` stays `[]` (handler ignores `effect_list`).

- [ ] **Step 3: Implement**

In `lib/govee_discovery_handler.rb#handle`, before `light.save!`, add:

```ruby
    effects = Array(data["effect_list"]).map(&:to_s).reject { |e| e.strip.empty? }
    light.firmware_scenes = effects if effects.any?
```

Update the class comment to note scenes come from `effect_list` (the `select` entity does not exist for these devices).

- [ ] **Step 4: Remove the dead select-based handler**

```bash
git rm lib/govee_scene_discovery_handler.rb test/govee_scene_discovery_handler_test.rb
```

In `bin/ziwoas_collector`, delete the `require "govee_scene_discovery_handler"` line and the `handlers << GoveeSceneDiscoveryHandler.new(logger: logger)` line.

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test TEST=test/govee_discovery_handler_test.rb`
Expected: PASS.
Run: `grep -rn "GoveeSceneDiscoveryHandler" .` → only matches in this plan/spec docs, none in `app`/`lib`/`bin`/`test`.

- [ ] **Step 6: Commit**

```bash
git add lib/govee_discovery_handler.rb test/govee_discovery_handler_test.rb bin/ziwoas_collector
git commit -m "fix(govee): read firmware_scenes from effect_list; drop dead select handler"
```

---

### Task 5: `LightState.zone_states` (per-zone on/off persistence)

**Files:**
- Create: `db/migrate/<ts>_add_zone_states_to_light_states.rb`
- Modify: `app/models/light_state.rb`, `db/schema.rb`
- Test: `test/models/light_state_test.rb` (create if absent)

**Interfaces:**
- Produces: `LightState#zone_states` → `Hash{String=>Boolean}` (default `{}`); `LightState.record_zone_state(light_key, instance, on)` → upserts one zone bit, returns `true` when it changed. Consumed by `GoveeZoneStateHandler` (Task 6) and `LightRow` (Task 7).

- [ ] **Step 1: Generate the migration**

Run: `bin/rails generate migration add_zone_states_to_light_states zone_states:text`
Edit to:

```ruby
class AddZoneStatesToLightStates < ActiveRecord::Migration[8.1]
  def change
    add_column :light_states, :zone_states, :text
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate`
Expected: `light_states` gains `t.text "zone_states"`.

- [ ] **Step 3: Write the failing test**

Create/extend `test/models/light_state_test.rb`:

```ruby
require "test_helper"

class LightStateTest < ActiveSupport::TestCase
  test "zone_states defaults to an empty hash" do
    assert_equal({}, LightState.new.zone_states)
  end

  test "record_zone_state upserts a single zone bit and reports change" do
    assert LightState.record_zone_state("UP1", "rippleLightToggle", true)
    state = LightState.find_by(light_key: "UP1")
    assert_equal({ "rippleLightToggle" => true }, state.zone_states)

    refute LightState.record_zone_state("UP1", "rippleLightToggle", true), "no change on identical write"
    assert LightState.record_zone_state("UP1", "rippleLightToggle", false), "change on flip"
    assert_equal({ "rippleLightToggle" => false }, LightState.find_by(light_key: "UP1").zone_states)
  end

  test "record_zone_state preserves other zones" do
    LightState.record_zone_state("UP1", "bottomLightToggle", true)
    LightState.record_zone_state("UP1", "sideLightToggle", true)
    assert_equal({ "bottomLightToggle" => true, "sideLightToggle" => true },
                 LightState.find_by(light_key: "UP1").zone_states)
  end
end
```

- [ ] **Step 4: Run to verify it fails**

Run: `bin/rails test TEST=test/models/light_state_test.rb`
Expected: FAIL (`zone_states` not serialized / `record_zone_state` undefined).

- [ ] **Step 5: Implement**

In `app/models/light_state.rb`:

```ruby
  serialize :zone_states, coder: JSON, type: Hash

  def zone_states = super || {}

  # Upserts one zone's on/off bit. Returns true when the stored value changed.
  def self.record_zone_state(light_key, instance, on)
    state = find_or_initialize_by(light_key: light_key)
    current = state.zone_states
    changed = current[instance] != on
    state.zone_states = current.merge(instance => on)
    state.save!
    changed
  end
```

- [ ] **Step 6: Run to verify it passes**

Run: `bin/rails test TEST=test/models/light_state_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/models/light_state.rb db/migrate db/schema.rb test/models/light_state_test.rb
git commit -m "feat(lights): light_states.zone_states + record_zone_state"
```

---

### Task 6: `GoveeZoneStateHandler` (toggle state → zone_states + broadcast)

**Files:**
- Create: `lib/govee_zone_state_handler.rb`
- Modify: `bin/ziwoas_collector`
- Test: `test/govee_zone_state_handler_test.rb`

**Interfaces:**
- Consumes: `gv2mqtt/switch/+/+/state` (`ON`/`OFF`); `Light::ZONE_META`; `LightState.record_zone_state`.
- Produces: updates `zone_states` and broadcasts `{ lights: [ { light_key:, zones: { <instance> => <bool> } } ] }` on the `"dashboard"` ActionCable stream (partial update the JS merges). Registered in the collector.

- [ ] **Step 1: Write the failing test**

Create `test/govee_zone_state_handler_test.rb` (mirror `test/govee_status_handler_test.rb` — capture broadcasts the same way it does):

```ruby
require "test_helper"
require "govee_zone_state_handler"
require "logger"
require "stringio"

class GoveeZoneStateHandlerTest < ActiveSupport::TestCase
  setup do
    LightState.delete_all
    @handler = GoveeZoneStateHandler.new(logger: Logger.new(StringIO.new))
  end

  test "subscribes to the per-zone switch state topic" do
    assert_equal [ "gv2mqtt/switch/+/+/state" ], @handler.subscriptions
  end

  test "matches a zone state topic but not a config topic" do
    assert @handler.matches?("gv2mqtt/switch/UP1/rippleLightToggle/state")
    refute @handler.matches?("gv2mqtt/switch/gv2mqtt-UP1-rippleLightToggle/config")
  end

  test "records a known zone toggle's ON state" do
    @handler.handle("gv2mqtt/switch/UP1/rippleLightToggle/state", "ON")
    assert_equal({ "rippleLightToggle" => true }, LightState.find_by(light_key: "UP1").zone_states)
  end

  test "ignores non-zone toggles (powerSwitch handled by the light state)" do
    @handler.handle("gv2mqtt/switch/UP1/powerSwitch/state", "ON")
    assert_nil LightState.find_by(light_key: "UP1")
  end

  test "broadcasts the changed zone bit on the dashboard stream" do
    payloads = []
    stub = ->(stream, data) { payloads << [ stream, data ] }
    ActionCable.server.stub(:broadcast, stub) do
      @handler.handle("gv2mqtt/switch/UP1/sideLightToggle/state", "OFF")
    end
    assert_equal "dashboard", payloads.first[0]
    assert_equal [ { light_key: "UP1", zones: { "sideLightToggle" => false } } ],
                 payloads.first[1][:lights]
  end
end
```

(If `test/govee_status_handler_test.rb` stubs ActionCable differently, copy that mechanism instead of `.stub`.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test TEST=test/govee_zone_state_handler_test.rb`
Expected: FAIL — file not found.

- [ ] **Step 3: Implement**

Create `lib/govee_zone_state_handler.rb`:

```ruby
# Consumes per-zone HA switch state (gv2mqtt/switch/<id>/<instance>/state =
# "ON"/"OFF") for lighting zones and reflects each bit into
# LightState#zone_states, broadcasting the change on the "dashboard" stream.
# Only Light::ZONE_META instances are tracked; powerSwitch (whole-lamp power)
# is left to GoveeStatusHandler via the light state topic.
class GoveeZoneStateHandler
  PREFIX = "gv2mqtt/switch/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{PREFIX}+/+/state" ]

  def matches?(topic)
    parts = topic.split("/")
    parts.length == 5 && parts[0] == "gv2mqtt" && parts[1] == "switch" && parts[4] == "state"
  end

  def handle(topic, payload)
    _, _, key, instance, _ = topic.split("/")
    return unless Light::ZONE_META.key?(instance)

    on = payload.to_s.strip == "ON"
    LightState.record_zone_state(key, instance, on)
    broadcast(key, instance, on)
  end

  private

  def broadcast(key, instance, on)
    ActionCable.server.broadcast("dashboard",
      { lights: [ { light_key: key, zones: { instance => on } } ] })
  rescue => e
    @logger.warn("GoveeZoneStateHandler: broadcast failed: #{e.message}")
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test TEST=test/govee_zone_state_handler_test.rb`
Expected: PASS.

- [ ] **Step 5: Register in the collector**

In `bin/ziwoas_collector`: `require "govee_zone_state_handler"` and `handlers << GoveeZoneStateHandler.new(logger: logger)`.

- [ ] **Step 6: Commit**

```bash
git add lib/govee_zone_state_handler.rb test/govee_zone_state_handler_test.rb bin/ziwoas_collector
git commit -m "feat(govee): reflect zone toggle state into zone_states + broadcast"
```

---

### Task 7: `LightRow` zone presenter + zone-aware default tab

**Files:**
- Modify: `app/models/light_row.rb`
- Test: `test/models/light_row_test.rb` (create if absent)

**Interfaces:**
- Consumes: `Light#zones`, `Light#zone_lamp?`, `Light::ZONE_META`, `LightState#zone_states`.
- Produces: `LightRow#zone_lamp?` (bool); `LightRow#zones` → `Array<Zone>` where `Zone = Struct.new(:key, :label, :role, :on)`, ordered main-first; `LightRow#default_tab` returns `"zones"` for zone lamps else the existing value. Consumed by the view (Task 9).

- [ ] **Step 1: Write the failing test**

Create/extend `test/models/light_row_test.rb`:

```ruby
require "test_helper"

class LightRowTest < ActiveSupport::TestCase
  test "zone_lamp? mirrors the light" do
    light = Light.new(zones: %w[bottomLightToggle sideLightToggle])
    assert LightRow.new(light: light, state: nil).zone_lamp?
  end

  test "zones presents main-first with labels and on-state" do
    light = Light.new(zones: %w[rippleLightToggle bottomLightToggle sideLightToggle])
    state = LightState.new(zone_states: { "bottomLightToggle" => true, "rippleLightToggle" => false })
    rows  = LightRow.new(light: light, state: state).zones
    assert_equal %w[bottomLightToggle rippleLightToggle sideLightToggle], rows.map(&:key)
    assert_equal "main", rows.first.role
    assert_equal "Leselicht", rows.first.label
    assert_equal true,  rows.first.on
    assert_equal false, rows[1].on # ripple, no state -> false
    assert_equal false, rows[2].on # side, missing -> false
  end

  test "default_tab is zones for a zone lamp" do
    light = Light.new(zones: %w[bottomLightToggle sideLightToggle])
    assert_equal "zones", LightRow.new(light: light, state: nil).default_tab
  end

  test "default_tab keeps the simple-lamp logic otherwise" do
    light = Light.new(zones: [])
    assert_equal "white", LightRow.new(light: light, state: nil).default_tab
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test TEST=test/models/light_row_test.rb`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `app/models/light_row.rb`:

```ruby
  Zone = Struct.new(:key, :label, :role, :on)

  def zone_lamp? = light.zone_lamp?

  def zones
    bits = state&.zone_states || {}
    light.zones.filter_map { |k|
      meta = Light::ZONE_META[k]
      next unless meta
      Zone.new(k, meta[:label], meta[:role], !!bits[k])
    }.sort_by { |z| z.role == "main" ? 0 : 1 }
  end
```

Change `default_tab`:

```ruby
  def default_tab
    return "zones" if zone_lamp?
    (on? && !white?) ? "color" : "white"
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test TEST=test/models/light_row_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/light_row.rb test/models/light_row_test.rb
git commit -m "feat(lights): LightRow zone presenter + zones default tab"
```

---

### Task 8: `LightSwitchesController` — `zone` command + power via `powerSwitch`

**Files:**
- Modify: `app/controllers/light_switches_controller.rb`
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: `GoveeCommander.set_zone` (Task 1), `Light#zones`, `Light#zone_lamp?`.
- Produces: new `zone` command (validated against the light's zones); `turn` routes zone lamps through `powerSwitch`. Returns `202` accepted on success, `422` for an unknown zone, `503` on MQTT error (existing rescue).

- [ ] **Step 1: Write the failing test**

In `test/controllers/light_switches_controller_test.rb`, add (match the existing test style — most likely it stubs `GoveeCommander` or asserts response codes via a fake MQTT factory; reuse that mechanism):

```ruby
test "zone command toggles a valid zone" do
  light = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
  GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) {
    assert_equal "rippleLightToggle", zone
    assert_equal true, on
  }) do
    post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "rippleLightToggle", on: "true" }
  end
  assert_response :accepted
end

test "zone command rejects a zone not on this light" do
  Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle])
  post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "powerSwitch", on: "true" }
  assert_response :unprocessable_entity
end

test "turn routes a zone lamp through powerSwitch" do
  light = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle sideLightToggle])
  called = {}
  GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) { called[:zone] = zone; called[:on] = on }) do
    post light_command_url(light_key: "UP1"), params: { command: "turn", on: "true" }
  end
  assert_equal "powerSwitch", called[:zone]
  assert_equal true, called[:on]
  assert_response :accepted
end

test "turn still uses the light command for a simple lamp" do
  Light.create!(name: "Lamp", key: "S1", zones: [])
  called = false
  GoveeCommander.stub(:turn, ->(l, on:, **) { called = true }) do
    post light_command_url(light_key: "S1"), params: { command: "turn", on: "false" }
  end
  assert called, "simple lamp uses GoveeCommander.turn"
  assert_response :accepted
end
```

(If the existing tests use a fake `mqtt_factory` instead of `GoveeCommander.stub`, follow that pattern; the assertions to preserve are the topic/zone routing and the response codes.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test TEST=test/controllers/light_switches_controller_test.rb -n /zone|powerSwitch|simple lamp/`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `app/controllers/light_switches_controller.rb`, change the `turn` branch and add the `zone` branch:

```ruby
    when "turn"
      if light.zone_lamp?
        GoveeCommander.set_zone(light, zone: "powerSwitch", on: cast_bool(params[:on]), **opts)
      else
        GoveeCommander.turn(light, on: cast_bool(params[:on]), **opts)
      end
    when "zone"
      return head :unprocessable_entity unless light.zones.include?(params[:zone])
      GoveeCommander.set_zone(light, zone: params[:zone], on: cast_bool(params[:on]), **opts)
```

(Leave `brightness|color|color_temp|effect|mood` and the rescue unchanged.)

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test TEST=test/controllers/light_switches_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "feat(lights): zone command + power zone lamps via powerSwitch"
```

---

### Task 9: Zonen-Tab view (tab, panel, zone cards, toast)

**Files:**
- Modify: `app/views/lights/show.html.erb`
- Test: `test/controllers/lights_controller_test.rb`

**Interfaces:**
- Consumes: `@row.zone_lamp?`, `@row.zones` (Task 7), `@light.max_active_zones` (Task 2).
- Produces: the `Zonen` tab + panel rendered for zone lamps; a hidden toast element; a `maxZones` Stimulus value. Consumed by the JS (Task 10) and CSS (Task 11).

- [ ] **Step 1: Write the failing test**

In `test/controllers/lights_controller_test.rb`, add (fixtures or inline create a zone lamp; match how the file builds lights + states):

```ruby
test "zone lamp renders a Zonen tab and one card per zone, main badged" do
  Light.create!(name: "Up", key: "UP1", sku: "H60B0",
                zones: %w[bottomLightToggle sideLightToggle rippleLightToggle])
  get light_url(key: "UP1")
  assert_response :success
  assert_select "button.ld-tab[data-light-detail-tab-param=zones]"
  assert_select ".ld-panel[data-tab=zones]"
  assert_select ".ld-zone", 3
  assert_select ".ld-zone.main .ld-zone-badge", text: "Haupt"
  # max-2 surfaced to the client + zones default tab
  assert_select ".ld[data-light-detail-max-zones-value='2']"
  assert_select ".ld[data-light-detail-tab-value=zones]"
  # whole-lamp tabs still present
  assert_select "button.ld-tab[data-light-detail-tab-param=white]"
end

test "simple lamp renders no Zonen tab" do
  Light.create!(name: "Lamp", key: "S1", supports_color: true)
  get light_url(key: "S1")
  assert_select "button.ld-tab[data-light-detail-tab-param=zones]", false
  assert_select ".ld-panel[data-tab=zones]", false
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb -n /zone|Zonen/`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `app/views/lights/show.html.erb`:

(a) Add the `maxZones` value to the root element:

```erb
<div class="ld" data-controller="light-detail"
     data-light-detail-key-value="<%= @light.key %>"
     data-light-detail-tab-value="<%= @row.default_tab %>"
     data-light-detail-max-zones-value="<%= @light.max_active_zones || 0 %>">
```

(b) In the `.ld-tabs` row, prepend the Zonen tab for zone lamps:

```erb
  <div class="ld-tabs">
    <% if @row.zone_lamp? %>
      <button class="ld-tab" data-action="light-detail#tab" data-light-detail-tab-param="zones">Zonen</button>
    <% end %>
    <button class="ld-tab" data-action="light-detail#tab" data-light-detail-tab-param="white">Weiß</button>
    <% if @light.supports_color %>
      <button class="ld-tab" data-action="light-detail#tab" data-light-detail-tab-param="color">Farbe</button>
    <% end %>
    <button class="ld-tab" data-action="light-detail#tab" data-light-detail-tab-param="scenes">Szenen</button>
  </div>
```

(c) Add the Zonen panel immediately before the `white` panel (so DOM order is Zonen → Weiß → Farbe → Szenen). The panel is hidden unless it is the default tab — `showTab` in JS manages visibility, so render it `hidden` unless `default_tab == "zones"`; simplest is to always render `hidden` and let `connect()`'s `showTab(default_tab)` reveal it (matches how the other panels rely on JS). Render only for zone lamps:

```erb
  <% if @row.zone_lamp? %>
    <div class="ld-panel" data-light-detail-target="panel" data-tab="zones" hidden>
      <% @row.zones.each do |zone| %>
        <div class="ld-zone<%= ' main' if zone.role == 'main' %><%= ' off' unless zone.on %>"
             data-zone-key="<%= zone.key %>" data-zone-role="<%= zone.role %>">
          <span class="ld-zone-dot"></span>
          <span class="ld-zone-nm"><%= zone.label %></span>
          <% if zone.role == "main" %><span class="ld-zone-badge">Haupt</span><% end %>
          <span class="ld-zone-spacer"></span>
          <button class="ld-zone-toggle<%= ' on' if zone.on %>"
                  data-action="light-detail#zone"
                  data-light-detail-zone-param="<%= zone.key %>"
                  data-light-detail-role-param="<%= zone.role %>"
                  aria-label="<%= zone.label %> an/aus"></button>
        </div>
      <% end %>
      <p class="ld-zone-hint">Farbe &amp; Weiß gelten für die ganze Lampe (Tabs oben).</p>
    </div>
  <% end %>
```

(d) Toast element (place once, just before the closing `.ld-error` line):

```erb
  <div class="ld-toast" data-light-detail-target="toast" hidden>
    <span data-light-detail-target="toastMsg"></span>
    <button class="ld-toast-undo" data-action="light-detail#undoZone">Rückgängig</button>
  </div>
```

(e) Optional copy tweak: in the colour panel `ld-label`, for zone lamps show the shared scope. Change `<p class="ld-label">Farbe</p>` to:

```erb
        <p class="ld-label"><%= @row.zone_lamp? ? "Farbe · Welle + Seite" : "Farbe" %></p>
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test TEST=test/controllers/lights_controller_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/views/lights/show.html.erb test/controllers/lights_controller_test.rb
git commit -m "feat(lights): Zonen tab with on/off zone cards + toast scaffold"
```

---

### Task 10: `light_detail` JS — zone toggle, max-2 rule, toast/undo, broadcast

**Files:**
- Modify: `app/javascript/controllers/light_detail_controller.js`
- Verify: render-asserted in Task 9; behaviour is **manual check** (no JS harness).

**Interfaces:**
- Consumes: `zone`/`role` action params, `maxZones` value, `.ld-zone` cards, toast targets (Task 9); `POST /lights/:key/command` with `command: "zone"`.
- Produces: optimistic zone toggling with the "max. 2" auto-off + toast/undo; reconciles `light.zones` from the broadcast.

- [ ] **Step 1: Add the `maxZones` value and toast targets**

In the `static values`/`static targets` declarations:

```js
  static values = { key: String, tab: String, maxZones: Number }
  static targets = ["panel", "brightness", "temp", "wheel", "error", "lamp", "toast", "toastMsg"]
```

- [ ] **Step 2: Implement the `zone` action + helpers**

Add these methods (after the scene/mood section):

```js
  // --- zones ---
  zone(event) {
    const key = event.params.zone
    const role = event.params.role
    const card = this.zoneCard(key)
    if (!card) return
    const turningOn = card.classList.contains("off")

    if (turningOn && role === "side" && this.maxZonesValue > 0) {
      const onCards = this.onZoneCards()
      if (onCards.length >= this.maxZonesValue) {
        const victim = this.victimSideCard(card)
        if (victim) {
          this.setZoneCard(victim, false)
          this.send({ command: "zone", zone: victim.dataset.zoneKey, on: "false" })
          this._undo = { victimKey: victim.dataset.zoneKey, newKey: key }
          this.showToast(`${this.zoneLabel(victim)} ausgeschaltet · max. ${this.maxZonesValue} Zonen`)
        }
      }
    }

    this.setZoneCard(card, turningOn)
    if (turningOn && role === "side") this._lastSide = key
    this.send({ command: "zone", zone: key, on: String(turningOn) })
  }

  undoZone() {
    if (!this._undo) return this.hideToast()
    const victim = this.zoneCard(this._undo.victimKey)
    const added = this.zoneCard(this._undo.newKey)
    if (victim) { this.setZoneCard(victim, true);  this.send({ command: "zone", zone: this._undo.victimKey, on: "true" }) }
    if (added)  { this.setZoneCard(added, false);  this.send({ command: "zone", zone: this._undo.newKey, on: "false" }) }
    this._lastSide = this._undo.victimKey
    this._undo = null
    this.hideToast()
  }

  // zone helpers
  zoneCard(key) { return this.element.querySelector(`.ld-zone[data-zone-key="${key}"]`) }
  zoneLabel(card) { return card.querySelector(".ld-zone-nm")?.textContent ?? "Zone" }
  onZoneCards() { return [...this.element.querySelectorAll(".ld-zone:not(.off)")] }

  victimSideCard(exclude) {
    const sides = this.onZoneCards().filter((c) => c.dataset.zoneRole === "side" && c !== exclude)
    const last = this._lastSide && sides.find((c) => c.dataset.zoneKey === this._lastSide)
    return last || sides[0] || null
  }

  setZoneCard(card, on) {
    card.classList.toggle("off", !on)
    card.querySelector(".ld-zone-toggle")?.classList.toggle("on", on)
  }

  showToast(msg) {
    if (!this.hasToastTarget) return
    if (this.hasToastMsgTarget) this.toastMsgTarget.textContent = msg
    this.toastTarget.hidden = false
    clearTimeout(this._toastTimer)
    this._toastTimer = setTimeout(() => this.hideToast(), 5000)
  }

  hideToast() {
    clearTimeout(this._toastTimer)
    this._undo = null
    if (this.hasToastTarget) this.toastTarget.hidden = true
  }
```

- [ ] **Step 3: Reconcile zones from the broadcast**

In `onBroadcast`, after the existing brightness/temp reconcile, add:

```js
    if (light.zones && typeof light.zones === "object") {
      for (const [key, on] of Object.entries(light.zones)) {
        const card = this.zoneCard(key)
        if (card) this.setZoneCard(card, on === true)
      }
    }
```

- [ ] **Step 4: Manual verification (no JS harness)**

Run the app (`bin/dev`, dev stack), open the Uplighter detail page, and confirm:
1. Zonen tab is default; three cards; Leselicht badged "Haupt".
2. Toggling Welle/Seite/Leselicht flips the card optimistically and the lamp follows.
3. With Leselicht + one side on, turning on the other side auto-offs the **last-activated** side, shows the toast; **Rückgängig** restores it.
4. Turning on a side never auto-offs Leselicht.
5. Note in the task report whether the hardware itself dropped a zone (possible double-toggle vs. our optimistic state).

State the result explicitly; do not claim automated coverage.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/light_detail_controller.js
git commit -m "feat(lights): zone toggling with max-2 auto-off, toast/undo, broadcast reconcile"
```

---

### Task 11: CSS — zone cards, toggles, main highlight, toast

**Files:**
- Modify: `app/assets/stylesheets/application.css`
- Verify: visual / manual.

**Interfaces:**
- Consumes: the markup classes from Task 9 (`.ld-zone`, `.ld-zone.main`, `.ld-zone.off`, `.ld-zone-dot/-nm/-badge/-spacer/-toggle`, `.ld-zone-hint`, `.ld-toast`, `.ld-toast-undo`).
- Produces: styled zone cards matching the uplighter-v2 mockup, reusing tokens.

- [ ] **Step 1: Add styles**

Append near the existing `.ld-*` detail styles (reuse the mockup's look — main = accent border, off = dimmed, toggle = pill):

```css
/* --- zone cards (multi-zone lamps) --- */
.ld-zone { display: flex; align-items: center; gap: 9px; background: var(--card, #fff);
           border: 1px solid var(--border, #dee2e6); border-radius: var(--radius-md, 14px);
           padding: 11px; margin-bottom: 9px; }
.ld-zone.main { border-color: var(--accent, #f59f00); box-shadow: 0 0 0 1px var(--accent, #f59f00) inset; }
.ld-zone.off { opacity: .5; }
.ld-zone-dot { width: 14px; height: 14px; border-radius: 50%; flex-shrink: 0;
               background: var(--accent, #f59f00); }
.ld-zone.off .ld-zone-dot { background: var(--border, #ced4da); }
.ld-zone-nm { font-weight: 600; font-size: 13px; }
.ld-zone-badge { font-size: 9px; font-weight: 700; text-transform: uppercase; letter-spacing: .4px;
                 background: var(--accent-bg, #ffe066); color: var(--accent-ink, #7c5e00);
                 border: 1px solid var(--accent, #f59f00); border-radius: var(--radius-sm, 6px);
                 padding: 1px 5px; }
.ld-zone-spacer { flex: 1; }
.ld-zone-toggle { width: 42px; height: 24px; border-radius: var(--radius-pill, 13px);
                  background: var(--offline, #ced4da); position: relative; flex-shrink: 0;
                  border: none; cursor: pointer; }
.ld-zone-toggle.on { background: var(--online, #40c057); }
.ld-zone-toggle::after { content: ""; position: absolute; top: 2px; left: 2px; width: 20px; height: 20px;
                         border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.3);
                         transition: left .15s ease; }
.ld-zone-toggle.on::after { left: 20px; }
.ld-zone-hint { font-size: 11px; color: var(--muted, #6c757d); margin: 6px 2px 0; }

/* --- toast (max-2 auto-off) --- */
.ld-toast { position: fixed; left: 16px; right: 16px; bottom: 16px; z-index: 20;
            display: flex; align-items: center; gap: 9px; background: #212529; color: #fff;
            border-radius: var(--radius-md, 12px); padding: 11px 13px; font-size: 12px;
            box-shadow: 0 6px 20px rgba(0,0,0,.3); }
.ld-toast[hidden] { display: none; }
.ld-toast-undo { margin-left: auto; background: none; border: none; cursor: pointer;
                 color: var(--accent-bg, #ffe066); font-weight: 700; }
```

(Match existing token names; if a token used above is not defined in `:root`, fall back to the literal already in the rule — the `var(--x, literal)` form does this. Prefer the real token where Phase 1 defined one.)

- [ ] **Step 2: Manual verification**

With the app running, confirm zone cards match the mockup (main highlighted, off dimmed, toggle slides), and the toast appears at the bottom with a working Rückgängig button. No console errors. State the result.

- [ ] **Step 3: Commit**

```bash
git add app/assets/stylesheets/application.css
git commit -m "style(lights): zone cards, toggles and max-2 toast"
```

---

### Task 12: Full check + manual smoke

**Files:** none (verification only).

- [ ] **Step 1: Stop the dev stack** (SQLite lock) — ensure no `bin/dev`/collector running.

- [ ] **Step 2: Run the full CI**

Run: `bin/ci`
Expected: rubocop, bundler-audit, importmap audit, brakeman, `rails test`, seeds — all green. (Schema changes from Tasks 2 & 5 regenerate `db/schema.rb`; if rubocop re-spaces the autogenerated schema, follow the Phase-1/2 convention — keep schema churn out, it is in the rubocop ignore.)

- [ ] **Step 3: Manual smoke (real lamp)** — start `bin/dev`, start the bridge (`bin/govee2mqtt`), trigger discovery (publish `online` to `gv2mqtt/status`, wait ~15s), then:
  1. Uplighter detail page shows the Zonen tab as default with 3 cards (Leselicht badged).
  2. Power on/off from the hero actually powers the lamp (powerSwitch path).
  3. Toggling each zone works; max-2 auto-off + toast + Rückgängig behave per Task 10 Step 4.
  4. Szenen tab now lists Govee scenes (effect_list populated `firmware_scenes`).
  5. Colour/white/brightness still affect the whole lamp.

Record outcomes (especially any hardware-enforced max-2 double-toggle) in the task report.

- [ ] **Step 4: Commit any schema/lockfile churn** produced by the run (if not already committed with their tasks).

---

## Self-Review (completed during planning)

- **Spec coverage:** Variante-B zone tab → Tasks 7/9/10/11; "max. 2" + main protection + toast/undo → Task 10; zone discovery/state/command backend → Tasks 1/3/5/6/8; scene-source fix (Backend-Auswirkung #2, corrected to effect_list) → Task 4; whole-lamp colour/white/brightness reuse → unchanged Phase-1/2 panels (noted in Task 9). Per-zone colour and live app-mirroring are explicit deferrals (impossible on this hardware).
- **Type consistency:** `zones` is `Array<String>` everywhere (Light → handler → LightRow); `zone_states` is `Hash{String=>Boolean}` (LightState → handler → LightRow → broadcast `light.zones`); `Zone` struct fields `key/label/role/on` are used identically in Task 7 and Task 9.
- **Placeholder scan:** every code step carries full code; migrations show exact content; tests show exact assertions. Manual-only steps (JS/CSS) are labelled as such, not claimed as automated.
- **Ordering robustness:** zone discovery and the light config can arrive in any order — `GoveeZoneDiscoveryHandler` find_or_initializes a placeholder-named Light, which `GoveeDiscoveryHandler`'s existing "name == key" rename logic later adopts.
