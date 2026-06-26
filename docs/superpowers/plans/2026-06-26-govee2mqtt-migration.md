# govee2mqtt Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ZiWoAS's homegrown Govee LAN/bridge stack with the `wez/govee2mqtt` service, consuming its HA-JSON MQTT topics, and auto-discover lamps by device-id.

**Architecture:** govee2mqtt owns all lamp I/O (LAN multicast + cloud). ZiWoAS becomes a pure MQTT client: `GoveeCommander` publishes HA-JSON to `gv2mqtt/light/{id}/command`; `GoveeStatusHandler` consumes `gv2mqtt/light/+/state` + `gv2mqtt/availability`; a new `GoveeDiscoveryHandler` upserts `Light` rows from retained `gv2mqtt/light/+/config`. The MqttRouter and web UI keep their shape.

**Tech Stack:** Ruby on Rails 8.1, Minitest, `mqtt` gem, SQLite, foreman (dev) / docker-compose (prod), Rust/Cargo (building govee2mqtt).

## Global Constraints

- **Device-id is stored verbatim.** `Light.key` = govee2mqtt's `topic_safe_id` (device-id, MAC-like 8-byte / 16-hex, e.g. `14ABDB4844064B60`), used unchanged in command/state topics. NEVER transform case — the id is deterministic per device and consistent across discovery/state/command; upcasing would break the command topic.
- **Every light command MUST include `state`.** govee2mqtt's `HassLightCommand.state` is non-optional → payloads without `state` fail to deserialize and are dropped; brightness/color alone do NOT power a light on. Every command carries `"state":"ON"` (or `"OFF"`).
- **`color_temp` is in mireds** on the wire: `mired = round(1_000_000 / kelvin)` and `kelvin = round(1_000_000 / mired)`. `brightness` scale is 100 (no conversion).
- **State is mode-dependent:** rgb mode carries `color` (+ `color_mode:"rgb"`); color_temp mode carries `color_temp` (+ `color_mode:"color_temp"`); never both. OFF is just `{"state":"OFF"}`. Handlers must tolerate absent fields and not clobber the other mode's last value.
- **Topic namespace** is unified under `gv2mqtt/*`: command/state/availability are hardcoded in govee2mqtt; we set the discovery prefix to `gv2mqtt` too via `--hass-discovery-prefix gv2mqtt`.
- **Discovery never deletes** and only sets `name` on first create (preserve user edits to name/room).
- Spec of record: [docs/superpowers/specs/2026-06-26-govee2mqtt-migration-design.md](../specs/2026-06-26-govee2mqtt-migration-design.md).
- Run tests with `bin/rails test <path>`; run one test with `-n <name>`.

---

## File Structure

**Delete:** `lib/govee_lan_client.rb`, `lib/govee_mqtt_bridge.rb`, `bin/govee_bridge`, `test/govee_lan_client_test.rb`, `test/govee_mqtt_bridge_test.rb`, `config/deploy.yml`, `bin/kamal`, `.kamal/`.

**Create:** `lib/govee_discovery_handler.rb`, `test/govee_discovery_handler_test.rb`, `bin/govee2mqtt` (dev wrapper), `config/govee2mqtt.env.example`, `docs/govee2mqtt-setup.md`.

**Modify:** `app/models/light.rb`, `db/migrate/20260624090100_create_lights.rb`, `db/schema.rb`, `lib/govee_commander.rb`, `lib/govee_status_handler.rb`, `app/controllers/lights_controller.rb`, `app/controllers/light_switches_controller.rb`, `app/controllers/scenes_controller.rb`, `app/views/lights/_form.html.erb`, `app/views/lights/index.html.erb`, `config/routes.rb`, `bin/ziwoas_collector`, `lib/config_loader.rb`, `config/ziwoas.example.yml`, `Procfile.dev`, `docker-compose.yml`, `.gitignore`, `Gemfile`, plus the test files that build `Light` records.

---

## Task 1: Delete the homegrown LAN stack

The LAN client + UDP bridge are fully replaced by govee2mqtt. Remove them first so nothing references `Light#ip_address` when Task 2 drops that column.

**Files:**
- Delete: `lib/govee_lan_client.rb`, `lib/govee_mqtt_bridge.rb`, `bin/govee_bridge`
- Delete: `test/govee_lan_client_test.rb`, `test/govee_mqtt_bridge_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (pure removal). `bin/ziwoas_collector` already does not depend on these.

- [ ] **Step 1: Confirm nothing else references the deleted units**

Run: `grep -rn "govee_lan_client\|govee_mqtt_bridge\|GoveeLanClient\|GoveeMqttBridge\|govee_bridge" app lib bin test config`
Expected: matches ONLY inside the five files being deleted (and `bin/govee_bridge` itself). If anything else matches, stop and reassess.

- [ ] **Step 2: Delete the files**

```bash
git rm lib/govee_lan_client.rb lib/govee_mqtt_bridge.rb bin/govee_bridge \
       test/govee_lan_client_test.rb test/govee_mqtt_bridge_test.rb
```

- [ ] **Step 3: Run the full test suite**

Run: `bin/rails test`
Expected: PASS (the two deleted test files are gone; nothing else referenced the deleted libs).

- [ ] **Step 4: Commit**

```bash
git commit -m "Remove homegrown Govee LAN client and UDP bridge"
```

---

## Task 2: Light identity — key = device-id, drop ip_address, discovery-only controller

`Light.key` becomes the verbatim device-id; `ip_address` is removed; lamps are managed by discovery, so manual create + LAN test-connection go away. The branch is not live, so the migration is reshaped in place.

**Files:**
- Modify: `db/migrate/20260624090100_create_lights.rb`, `db/schema.rb`
- Modify: `app/models/light.rb`
- Modify: `app/controllers/lights_controller.rb`, `config/routes.rb`
- Modify: `app/views/lights/_form.html.erb`, `app/views/lights/index.html.erb`
- Delete: `app/views/lights/new.html.erb`
- Test: `test/models/light_test.rb`, `test/controllers/lights_controller_test.rb`
- Test (compile-fix the `Light.create!` calls): `test/models/light_row_test.rb`, `test/models/scene_test.rb`, `test/controllers/light_switches_controller_test.rb`, `test/controllers/scenes_controller_test.rb`, `test/govee_commander_test.rb`, `test/govee_status_handler_test.rb`

**Interfaces:**
- Produces: `Light#key` (String, verbatim device-id, required, unique, format `/\A[0-9A-Za-z]+\z/`); no `ip_address`; no auto key generation. `Light#to_param == key`. `LightsController` actions: `index`, `edit`, `update`, `destroy` only.

- [ ] **Step 1: Rewrite the Light model test**

Replace the entire contents of `test/models/light_test.rb`:

```ruby
# test/models/light_test.rb
require "test_helper"

class LightTest < ActiveSupport::TestCase
  test "valid with a name and a device-id key" do
    assert Light.new(name: "Stehlampe", key: "14ABDB4844064B60").valid?
  end

  test "requires a name" do
    refute Light.new(name: "", key: "14ABDB4844064B60").valid?
  end

  test "requires a key" do
    refute Light.new(name: "Stehlampe", key: "").valid?
  end

  test "key must be unique" do
    Light.create!(name: "Eins", key: "14ABDB4844064B60")
    refute Light.new(name: "Zwei", key: "14ABDB4844064B60").valid?
  end

  test "key rejects non-alphanumeric characters" do
    refute Light.new(name: "X", key: "14:AB:DB").valid?
  end

  test "key is stored verbatim (case preserved)" do
    light = Light.create!(name: "Mixed", key: "14abDB4844064b60")
    assert_equal "14abDB4844064b60", light.reload.key
  end

  test "to_param is the key" do
    light = Light.create!(name: "Bad", key: "A1B2C3D4E5F60001")
    assert_equal "A1B2C3D4E5F60001", light.to_param
  end

  test "optionally belongs to a room" do
    room  = Room.create!(name: "Salon")
    light = Light.create!(name: "Salon Lampe", key: "A1B2C3D4E5F60002", room: room)
    assert_equal room, light.room
    assert_includes room.lights, light
  end
end
```

- [ ] **Step 2: Run the model test to verify it fails**

Run: `bin/rails test test/models/light_test.rb`
Expected: FAIL (model still requires `ip_address`, still auto-generates `key`, allows wrong format).

- [ ] **Step 3: Rewrite the Light model**

Replace the entire contents of `app/models/light.rb`:

```ruby
class Light < ApplicationRecord
  belongs_to :room, optional: true

  validates :name, presence: true
  validates :key,  presence: true, uniqueness: true,
                   format: { with: /\A[0-9A-Za-z]+\z/ }

  def to_param = key
end
```

- [ ] **Step 4: Reshape the lights migration (drop ip_address)**

Edit `db/migrate/20260624090100_create_lights.rb` — remove the `ip_address` line so the body reads:

```ruby
class CreateLights < ActiveRecord::Migration[8.1]
  def change
    create_table :lights do |t|
      t.string  :key,            null: false
      t.string  :name,           null: false
      t.references :room,        foreign_key: true, null: true
      t.string  :sku
      t.string  :shelly_plug_id
      t.boolean :supports_color,      null: false, default: false
      t.boolean :supports_color_temp, null: false, default: false
      t.timestamps
    end
    add_index :lights, :key, unique: true
  end
end
```

- [ ] **Step 5: Re-run the migration to regenerate schema.rb**

```bash
bin/rails db:migrate:down VERSION=20260624090100
bin/rails db:migrate:up VERSION=20260624090100
bin/rails db:test:prepare
```
Expected: `db/schema.rb` no longer contains `ip_address` under `create_table "lights"`. Verify: `grep -n ip_address db/schema.rb` → no matches.

- [ ] **Step 6: Run the model test to verify it passes**

Run: `bin/rails test test/models/light_test.rb`
Expected: PASS.

- [ ] **Step 7: Trim LightsController to discovery-only**

Replace the entire contents of `app/controllers/lights_controller.rb`:

```ruby
class LightsController < ApplicationController
  before_action :set_light, only: %i[edit update destroy]

  def index = (@lights = Light.includes(:room).order(:name))
  def edit; end

  def update
    if @light.update(light_params)
      redirect_to lights_url, notice: "Lampe aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @light.destroy
    redirect_to lights_url, notice: "Lampe gelöscht."
  end

  private

  def set_light = (@light = Light.find_by!(key: params[:key]))

  def light_params
    params.require(:light).permit(:name, :room_id, :shelly_plug_id,
                                  :supports_color, :supports_color_temp)
  end
end
```

- [ ] **Step 8: Remove the dropped routes (new/create/test_connection)**

In `config/routes.rb`, change the lights resource block so only `edit`, `update`, `destroy` remain and the `test_connection` member route is gone. Replace lines 11–13 (the `resources :lights ... do ... end` block):

```ruby
  resources :lights, param: :key, only: %i[edit update destroy]
```

(Verify there is no remaining `test_connection` or `new_light`/`POST lights` route: `grep -n "test_connection\|lights#new\|lights#create" config/routes.rb` → no matches.)

- [ ] **Step 9: Update the lights views**

Edit `app/views/lights/_form.html.erb` — remove the IP-address label+field (the two lines for `:ip_address`). The form keeps name, room, shelly_plug_id, supports_color, supports_color_temp.

Replace the entire contents of `app/views/lights/index.html.erb`:

```erb
<%# app/views/lights/index.html.erb %>
<% content_for :title, "Lampen" %>
<h1>Lampen</h1>
<%= link_to "Räume", rooms_path %>
<ul>
  <% @lights.each do |light| %>
    <li>
      <%= light.name %><%= " · #{light.room.name}" if light.room %>
      <span class="light-key"><%= light.key %></span>
      <%= link_to "Bearbeiten", edit_light_path(light) %>
      <%= button_to "Löschen", light_path(light), method: :delete,
                    form: { data: { turbo_confirm: "Lampe wirklich löschen?" } } %>
    </li>
  <% end %>
</ul>
```

Delete the now-unused new template:

```bash
git rm app/views/lights/new.html.erb
```

- [ ] **Step 10: Rewrite the LightsController test**

Replace the entire contents of `test/controllers/lights_controller_test.rb`:

```ruby
# test/controllers/lights_controller_test.rb
require "test_helper"

class LightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    Room.delete_all
  end

  test "index lists lights" do
    Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60001")
    get lights_url
    assert_response :success
    assert_match "Stehlampe", @response.body
  end

  test "update edits a light's name and room by key" do
    room  = Room.create!(name: "Wohnzimmer")
    light = Light.create!(name: "Lampe", key: "A1B2C3D4E5F60002")
    patch light_url(light), params: { light: { name: "Stehlampe", room_id: room.id } }
    assert_redirected_to lights_url
    light.reload
    assert_equal "Stehlampe", light.name
    assert_equal room, light.room
  end

  test "destroy removes a light" do
    light = Light.create!(name: "Weg", key: "A1B2C3D4E5F60003")
    assert_difference -> { Light.count }, -1 do
      delete light_url(light)
    end
  end

  test "there is no manual create route" do
    assert_raises(ActionController::UrlGenerationError) { new_light_path }
  end
end
```

- [ ] **Step 11: Compile-fix the remaining `Light.create!` calls (drop ip_address, add key)**

These tests build `Light` records with `ip_address:`. Change each to pass an explicit `key:` instead. Apply exactly:

`test/models/light_row_test.rb`
- Line 11: `Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")` → `Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60010")`
- Line 24: `Light.create!(name: "Neu", ip_address: "192.168.10.21")` → `Light.create!(name: "Neu", key: "A1B2C3D4E5F60011")`

`test/models/scene_test.rb`
- Line 5: `@light  = Light.create!(name: "Kino Lampe", ip_address: "192.168.10.40")` → `@light  = Light.create!(name: "Kino Lampe", key: "A1B2C3D4E5F60020")`

`test/controllers/light_switches_controller_test.rb`
- Line 7: `@light = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")` → `@light = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60030")`
- In the "turn calls GoveeCommander" test, the assertion `assert_equal [ [ "stehlampe", true ] ], @calls` → `assert_equal [ [ "A1B2C3D4E5F60030", true ] ], @calls`

`test/controllers/scenes_controller_test.rb`
- Line 19: `light  = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")` → `light  = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60040")`
- The assertion `assert_equal [ [ "stehlampe", true ] ], turns` → `assert_equal [ [ "A1B2C3D4E5F60040", true ] ], turns`

`test/govee_commander_test.rb`
- In `setup`: `@light = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")` → `@light = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60050")`
  (This file is fully rewritten in Task 3; this keeps it compiling now.)

`test/govee_status_handler_test.rb`
- In the "handle fills the light sku" test: `Light.create!(name: "Lampe", key: "lamp", ip_address: "192.168.10.20")` → `Light.create!(name: "Lampe", key: "lamp")`
  (This file is fully rewritten in Task 4; this keeps it compiling now.)

- [ ] **Step 12: Run the full suite**

Run: `bin/rails test`
Expected: PASS. If `govee_commander_test` or `govee_status_handler_test` fail on topic/payload assertions, that is expected to be addressed in Tasks 3/4 — but they should at least no longer raise `unknown attribute 'ip_address'`. If any OTHER failure references `ip_address`, fix that call site the same way (`grep -rn ip_address app test`).

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "Make Light.key the device-id, drop ip_address, discovery-only LightsController"
```

---

## Task 3: GoveeCommander → HA-JSON publisher

Rewrite the commander to publish Home-Assistant JSON-light commands to `gv2mqtt/light/{key}/command`, with mandatory `state` and Kelvin→mired conversion. Update the two call sites (they stub the commander in their own tests, so only the call kwargs change).

**Files:**
- Modify: `lib/govee_commander.rb`
- Modify: `app/controllers/light_switches_controller.rb`, `app/controllers/scenes_controller.rb`
- Test: `test/govee_commander_test.rb`

**Interfaces:**
- Produces: `GoveeCommander.turn(light, on:, mqtt_config:, mqtt_factory: nil)`, `.set_brightness(light, value:, mqtt_config:, mqtt_factory: nil)`, `.set_color(light, r:, g:, b:, mqtt_config:, mqtt_factory: nil)`, `.set_color_temp(light, kelvin:, mqtt_config:, mqtt_factory: nil)`, `.kelvin_to_mired(kelvin) -> Integer`. No `source:`, no `topic_prefix:`, no `refresh`. Raises `GoveeCommander::Error` on publish failure.

- [ ] **Step 1: Rewrite the commander test**

Replace the entire contents of `test/govee_commander_test.rb`:

```ruby
# test/govee_commander_test.rb
require "test_helper"
require "config_loader"
require "govee_commander"

class GoveeCommanderTest < ActiveSupport::TestCase
  class FakeMqtt
    attr_reader :published, :disconnected
    def initialize(fail_connect: false)
      @fail_connect = fail_connect
      @published    = []
      @disconnected = false
    end
    def connect = (raise(Errno::ECONNREFUSED, "broker down") if @fail_connect)
    def publish(topic, payload) = @published << [ topic, payload ]
    def disconnect = @disconnected = true
  end

  setup do
    @mqtt_config = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @light = Light.create!(name: "Stehlampe", key: "14ABDB4844064B60")
  end

  def opts(client) = { mqtt_config: @mqtt_config, mqtt_factory: -> { client } }

  test "turn ON publishes HA-JSON state to the device command topic" do
    c = FakeMqtt.new
    GoveeCommander.turn(@light, on: true, **opts(c))
    topic, payload = c.published.first
    assert_equal "gv2mqtt/light/14ABDB4844064B60/command", topic
    assert_equal({ "state" => "ON" }, JSON.parse(payload))
    assert c.disconnected
  end

  test "turn OFF publishes state OFF" do
    c = FakeMqtt.new
    GoveeCommander.turn(@light, on: false, **opts(c))
    assert_equal({ "state" => "OFF" }, JSON.parse(c.published.first[1]))
  end

  test "set_brightness includes state ON and the integer value" do
    c = FakeMqtt.new
    GoveeCommander.set_brightness(@light, value: 42, **opts(c))
    assert_equal({ "state" => "ON", "brightness" => 42 }, JSON.parse(c.published.first[1]))
  end

  test "set_color includes state ON and rgb" do
    c = FakeMqtt.new
    GoveeCommander.set_color(@light, r: 255, g: 100, b: 0, **opts(c))
    assert_equal({ "state" => "ON", "color" => { "r" => 255, "g" => 100, "b" => 0 } },
                 JSON.parse(c.published.first[1]))
  end

  test "set_color_temp converts kelvin to mired and includes state ON" do
    c = FakeMqtt.new
    GoveeCommander.set_color_temp(@light, kelvin: 4000, **opts(c))
    # 1_000_000 / 4000 = 250
    assert_equal({ "state" => "ON", "color_temp" => 250 }, JSON.parse(c.published.first[1]))
  end

  test "kelvin_to_mired rounds" do
    assert_equal 370, GoveeCommander.kelvin_to_mired(2700) # 370.37 -> 370
  end

  test "publish failure raises GoveeCommander::Error" do
    c = FakeMqtt.new(fail_connect: true)
    assert_raises(GoveeCommander::Error) do
      GoveeCommander.turn(@light, on: true, **opts(c))
    end
  end
end
```

- [ ] **Step 2: Run the commander test to verify it fails**

Run: `bin/rails test test/govee_commander_test.rb`
Expected: FAIL (old commander uses `govee/<key>/command/<cmd>` topics and a `topic_prefix:` kwarg).

- [ ] **Step 3: Rewrite the commander**

Replace the entire contents of `lib/govee_commander.rb`:

```ruby
require "mqtt"
require "json"

# Web-side choke point for Govee commands. Publishes Home-Assistant JSON-light
# commands over a short-lived MQTT connection to govee2mqtt's per-device command
# topic. `state` is mandatory in every command: govee2mqtt rejects payloads
# without it, and brightness/color alone do not power a light on.
class GoveeCommander
  class Error < StandardError; end

  COMMAND_TOPIC = "gv2mqtt/light/%s/command"

  def self.turn(light, on:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => (on ? "ON" : "OFF") }, mqtt_config:, mqtt_factory:)
  end

  def self.set_brightness(light, value:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "brightness" => value.to_i }, mqtt_config:, mqtt_factory:)
  end

  def self.set_color(light, r:, g:, b:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "color" => { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i } },
            mqtt_config:, mqtt_factory:)
  end

  def self.set_color_temp(light, kelvin:, mqtt_config:, mqtt_factory: nil)
    publish(light, { "state" => "ON", "color_temp" => kelvin_to_mired(kelvin) },
            mqtt_config:, mqtt_factory:)
  end

  def self.kelvin_to_mired(kelvin) = (1_000_000.0 / kelvin.to_i).round

  def self.publish(light, payload, mqtt_config:, mqtt_factory: nil)
    factory = mqtt_factory || -> { MQTT::Client.new(host: mqtt_config.host, port: mqtt_config.port) }
    client  = factory.call
    begin
      client.connect
      client.publish(format(COMMAND_TOPIC, light.key), JSON.generate(payload))
    rescue StandardError => e
      raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end
```

- [ ] **Step 4: Run the commander test to verify it passes**

Run: `bin/rails test test/govee_commander_test.rb`
Expected: PASS.

- [ ] **Step 5: Update the LightSwitchesController call site**

Replace the entire contents of `app/controllers/light_switches_controller.rb`:

```ruby
# app/controllers/light_switches_controller.rb
require "govee_commander"

class LightSwitchesController < ApplicationController
  def create
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    case params[:command]
    when "turn"
      GoveeCommander.turn(light, on: cast_bool(params[:on]), **opts)
    when "brightness"
      GoveeCommander.set_brightness(light, value: params[:value].to_i, **opts)
    when "color"
      GoveeCommander.set_color(light, r: params[:r].to_i, g: params[:g].to_i, b: params[:b].to_i, **opts)
    when "color_temp"
      GoveeCommander.set_color_temp(light, kelvin: params[:temp_k].to_i, **opts)
    else
      return head :unprocessable_entity
    end

    head :accepted
  rescue GoveeCommander::Error
    head :service_unavailable
  end

  private

  def opts = { mqtt_config: app_config.mqtt }
  def cast_bool(v) = ActiveModel::Type::Boolean.new.cast(v)
end
```

- [ ] **Step 6: Update the ScenesController call site**

In `app/controllers/scenes_controller.rb`, replace the `apply_entry` and `opts` private methods (drop `source:` and the `topic_prefix` in `opts`):

```ruby
  def apply_entry(entry)
    light, preset = entry.light, entry.preset
    GoveeCommander.turn(light, on: preset.on, **opts)
    return unless preset.on
    GoveeCommander.set_brightness(light, value: preset.brightness, **opts) if preset.brightness
    if preset.color_temp_k && preset.color_temp_k > 0
      GoveeCommander.set_color_temp(light, kelvin: preset.color_temp_k, **opts)
    elsif preset.color_r
      GoveeCommander.set_color(light, r: preset.color_r, g: preset.color_g, b: preset.color_b, **opts)
    end
  end

  def opts = { mqtt_config: app_config.mqtt }
```

- [ ] **Step 7: Run the affected suites**

Run: `bin/rails test test/govee_commander_test.rb test/controllers/light_switches_controller_test.rb test/controllers/scenes_controller_test.rb`
Expected: PASS (the controller tests stub `GoveeCommander`, so they accept the new kwargs).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Rewrite GoveeCommander as HA-JSON publisher to gv2mqtt command topic"
```

---

## Task 4: GoveeStatusHandler → gv2mqtt state + availability consumer

Consume `gv2mqtt/light/+/state` (HA-JSON, mode-dependent, mired→Kelvin) and `gv2mqtt/availability` (online/offline → reachability). Key `LightState` by the device-id from the topic. sku no longer comes from state (it comes from discovery).

**Files:**
- Modify: `lib/govee_status_handler.rb`
- Test: `test/govee_status_handler_test.rb`

**Interfaces:**
- Consumes: `LightState.record_state(key, attrs)` (existing).
- Produces: `GoveeStatusHandler.new(logger:)`; `#subscriptions == ["gv2mqtt/light/+/state", "gv2mqtt/availability"]`; `#matches?(topic)`; `#handle(topic, payload)`.

- [ ] **Step 1: Rewrite the status handler test**

Replace the entire contents of `test/govee_status_handler_test.rb`:

```ruby
# test/govee_status_handler_test.rb
require "test_helper"
require "govee_status_handler"
require "logger"
require "stringio"

class GoveeStatusHandlerTest < ActiveSupport::TestCase
  setup do
    LightState.delete_all
    Light.delete_all
    @log_io  = StringIO.new
    @handler = GoveeStatusHandler.new(logger: Logger.new(@log_io))
  end

  def state_topic(key) = "gv2mqtt/light/#{key}/state"

  def capture_broadcasts
    broadcasts = []
    server   = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, data| broadcasts << [ stream, data ] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "subscriptions cover state and availability" do
    assert_equal [ "gv2mqtt/light/+/state", "gv2mqtt/availability" ], @handler.subscriptions
  end

  test "matches state topics and the availability topic only" do
    assert @handler.matches?("gv2mqtt/light/14ABDB4844064B60/state")
    assert @handler.matches?("gv2mqtt/availability")
    refute @handler.matches?("gv2mqtt/light/gv2mqtt-14ABDB4844064B60/config")
    refute @handler.matches?("shellies/bkw/status/switch:0")
  end

  test "handle records on/brightness/color from rgb-mode state" do
    @handler.handle(state_topic("14ABDB4844064B60"),
      JSON.generate({ "state" => "ON", "brightness" => 60, "color_mode" => "rgb",
                      "color" => { "r" => 10, "g" => 20, "b" => 30 } }))
    s = LightState.find_by(light_key: "14ABDB4844064B60")
    assert_equal true, s.on
    assert_equal 60,   s.brightness
    assert_equal 30,   s.color_b
    assert_equal true, s.reachable
  end

  test "handle converts color_temp mireds to kelvin" do
    @handler.handle(state_topic("ABC123"),
      JSON.generate({ "state" => "ON", "brightness" => 80, "color_mode" => "color_temp",
                      "color_temp" => 250 }))
    s = LightState.find_by(light_key: "ABC123")
    # 1_000_000 / 250 = 4000
    assert_equal 4000, s.color_temp_k
  end

  test "handle does not clobber color when a color_temp-only update arrives" do
    @handler.handle(state_topic("ABC123"),
      JSON.generate({ "state" => "ON", "color" => { "r" => 1, "g" => 2, "b" => 3 } }))
    @handler.handle(state_topic("ABC123"),
      JSON.generate({ "state" => "ON", "color_temp" => 500 }))
    s = LightState.find_by(light_key: "ABC123")
    assert_equal 1,    s.color_r, "previous rgb must be preserved"
    assert_equal 2000, s.color_temp_k
  end

  test "handle marks the light off on state OFF" do
    @handler.handle(state_topic("ABC123"), JSON.generate({ "state" => "OFF" }))
    assert_equal false, LightState.find_by(light_key: "ABC123").on
  end

  test "handle broadcasts the light state on the dashboard stream" do
    capture_broadcasts do |broadcasts|
      @handler.handle(state_topic("ABC123"), JSON.generate({ "state" => "ON", "brightness" => 55 }))
      stream, data = broadcasts.first
      assert_equal "dashboard", stream
      assert_equal "ABC123", data[:lights].first[:light_key]
      assert_equal 55,       data[:lights].first[:brightness]
    end
  end

  test "availability offline marks all known lights unreachable" do
    LightState.record_state("ABC123", on: true, reachable: true)
    @handler.handle("gv2mqtt/availability", "offline")
    assert_equal false, LightState.find_by(light_key: "ABC123").reachable
  end

  test "availability online is a no-op" do
    LightState.record_state("ABC123", on: true, reachable: true)
    @handler.handle("gv2mqtt/availability", "online")
    assert_equal true, LightState.find_by(light_key: "ABC123").reachable
  end

  test "handle ignores invalid JSON" do
    assert_nothing_raised { @handler.handle(state_topic("ABC123"), "not-json{") }
    assert_equal 0, LightState.count
    assert_match(/invalid json/i, @log_io.string)
  end
end
```

- [ ] **Step 2: Run the status handler test to verify it fails**

Run: `bin/rails test test/govee_status_handler_test.rb`
Expected: FAIL (old handler uses `govee/+/status` and a `topic_prefix:` kwarg).

- [ ] **Step 3: Rewrite the status handler**

Replace the entire contents of `lib/govee_status_handler.rb`:

```ruby
require "json"

# Consumes govee2mqtt's HA-JSON light state (gv2mqtt/light/<id>/state) and the
# global availability topic (gv2mqtt/availability). Upserts LightState keyed by
# the device id and broadcasts changes on the "dashboard" ActionCable stream.
class GoveeStatusHandler
  STATE_PREFIX     = "gv2mqtt/light/"
  AVAILABILITY     = "gv2mqtt/availability"
  BROADCAST_FIELDS = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "gv2mqtt/light/+/state", AVAILABILITY ]

  def matches?(topic)
    topic == AVAILABILITY || (topic.start_with?(STATE_PREFIX) && topic.end_with?("/state"))
  end

  def handle(topic, payload)
    return handle_availability(payload) if topic == AVAILABILITY
    handle_state(topic, payload)
  end

  private

  def handle_state(topic, payload)
    key   = topic.split("/")[2]
    data  = JSON.parse(payload)
    attrs = parse_state(data).merge(last_seen_at: Time.current)
    LightState.record_state(key, attrs)
    broadcast(key, attrs)
  rescue JSON::ParserError => e
    @logger.warn("GoveeStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  # "offline" means govee2mqtt is gone (its LWT): mark every light unreachable.
  # "online" is a no-op; per-device state refreshes naturally.
  def handle_availability(payload)
    return unless payload.to_s.strip == "offline"
    LightState.where(reachable: true).update_all(reachable: false)
    broadcast_all_unreachable
  end

  # State is mode-dependent: rgb mode carries "color"; color_temp mode carries
  # "color_temp" (mireds); never both. Absent fields stay out of attrs so we
  # never clobber the other mode's last-known values.
  def parse_state(data)
    attrs = { on: data["state"] == "ON", reachable: true }
    attrs[:brightness] = data["brightness"] if data.key?("brightness")
    if (c = data["color"])
      attrs[:color_r] = c["r"]; attrs[:color_g] = c["g"]; attrs[:color_b] = c["b"]
    end
    attrs[:color_temp_k] = mired_to_kelvin(data["color_temp"]) if data["color_temp"]
    attrs
  end

  def mired_to_kelvin(mired) = (1_000_000.0 / mired.to_i).round

  def broadcast(key, attrs)
    payload = attrs.slice(*BROADCAST_FIELDS).merge(light_key: key)
    ActionCable.server.broadcast("dashboard", { lights: [ payload ] })
  rescue => e
    @logger.warn("GoveeStatusHandler: ActionCable broadcast failed: #{e.message}")
  end

  def broadcast_all_unreachable
    lights = LightState.all.map { |s| { light_key: s.light_key, reachable: false } }
    ActionCable.server.broadcast("dashboard", { lights: lights }) if lights.any?
  rescue => e
    @logger.warn("GoveeStatusHandler: ActionCable broadcast failed: #{e.message}")
  end
end
```

- [ ] **Step 4: Run the status handler test to verify it passes**

Run: `bin/rails test test/govee_status_handler_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Rewrite GoveeStatusHandler for gv2mqtt state + availability"
```

---

## Task 5: GoveeDiscoveryHandler (new)

Consume retained `gv2mqtt/light/+/config`, upsert `Light` by the bare device-id parsed from the config's `state_topic`. Set `name` only on create; refresh `sku` and capabilities each time; never delete.

**Files:**
- Create: `lib/govee_discovery_handler.rb`
- Test: `test/govee_discovery_handler_test.rb`

**Interfaces:**
- Produces: `GoveeDiscoveryHandler.new(logger:)`; `#subscriptions == ["gv2mqtt/light/+/config"]`; `#matches?(topic)`; `#handle(topic, payload)`. Reads payload `name`, `state_topic`, `supported_color_modes`, `device.model`.

- [ ] **Step 1: Write the failing test**

Create `test/govee_discovery_handler_test.rb`:

```ruby
# test/govee_discovery_handler_test.rb
require "test_helper"
require "govee_discovery_handler"
require "logger"
require "stringio"

class GoveeDiscoveryHandlerTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    @log_io  = StringIO.new
    @handler = GoveeDiscoveryHandler.new(logger: Logger.new(@log_io))
  end

  def config(overrides = {})
    JSON.generate({
      "name"        => "Floor Lamp",
      "state_topic" => "gv2mqtt/light/14ABDB4844064B60/state",
      "supported_color_modes" => [ "rgb", "color_temp" ],
      "device"      => { "model" => "H607C" }
    }.merge(overrides))
  end

  test "subscriptions targets the discovery config topic" do
    assert_equal [ "gv2mqtt/light/+/config" ], @handler.subscriptions
  end

  test "matches discovery config topics only" do
    assert @handler.matches?("gv2mqtt/light/gv2mqtt-14ABDB4844064B60/config")
    refute @handler.matches?("gv2mqtt/light/14ABDB4844064B60/state")
  end

  test "creates a Light keyed by the bare device-id from state_topic" do
    @handler.handle("gv2mqtt/light/gv2mqtt-14ABDB4844064B60/config", config)
    light = Light.find_by(key: "14ABDB4844064B60")
    assert_not_nil light
    assert_equal "Floor Lamp", light.name
    assert_equal "H607C",      light.sku
    assert_equal true,  light.supports_color
    assert_equal true,  light.supports_color_temp
  end

  test "maps capabilities from supported_color_modes" do
    @handler.handle("gv2mqtt/light/x/config",
      config("supported_color_modes" => [ "color_temp" ]))
    light = Light.find_by(key: "14ABDB4844064B60")
    assert_equal false, light.supports_color
    assert_equal true,  light.supports_color_temp
  end

  test "re-discovery preserves a user-renamed light but refreshes capabilities" do
    Light.create!(name: "Mein Name", key: "14ABDB4844064B60",
                  supports_color: false, supports_color_temp: false)
    @handler.handle("gv2mqtt/light/x/config", config)
    light = Light.find_by(key: "14ABDB4844064B60")
    assert_equal "Mein Name", light.name, "user name must be preserved"
    assert_equal true, light.supports_color, "capabilities are refreshed"
  end

  test "never deletes; an unrelated light is untouched" do
    Light.create!(name: "Andere", key: "FFFFFFFFFFFFFFFF")
    @handler.handle("gv2mqtt/light/x/config", config)
    assert Light.exists?(key: "FFFFFFFFFFFFFFFF")
  end

  test "ignores a config without a usable state_topic" do
    @handler.handle("gv2mqtt/light/x/config",
      JSON.generate({ "name" => "X", "supported_color_modes" => [ "rgb" ] }))
    assert_equal 0, Light.count
    assert_match(/no state_topic/i, @log_io.string)
  end

  test "ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("gv2mqtt/light/x/config", "not-json{") }
    assert_equal 0, Light.count
    assert_match(/invalid json/i, @log_io.string)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/govee_discovery_handler_test.rb`
Expected: FAIL with "cannot load such file -- govee_discovery_handler".

- [ ] **Step 3: Write the discovery handler**

Create `lib/govee_discovery_handler.rb`:

```ruby
require "json"

# Consumes govee2mqtt's retained Home-Assistant discovery configs
# (gv2mqtt/light/<unique_id>/config) and upserts Light rows, keyed by the bare
# device id parsed from the config's state_topic (the topic-path node is the
# unique_id "gv2mqtt-<id>", so we do NOT use it). Never deletes; sets name only
# on first create so user edits to name/room are preserved.
class GoveeDiscoveryHandler
  DISCOVERY_PREFIX = "gv2mqtt"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "#{DISCOVERY_PREFIX}/light/+/config" ]

  def matches?(topic)
    topic.start_with?("#{DISCOVERY_PREFIX}/light/") && topic.end_with?("/config")
  end

  def handle(topic, payload)
    data = JSON.parse(payload)
    key  = device_id_from(data["state_topic"])
    return @logger.warn("GoveeDiscoveryHandler: no state_topic in config on #{topic}") unless key

    light = Light.find_or_initialize_by(key: key)
    light.name = data["name"].presence || key if light.new_record?
    model = data.dig("device", "model")
    light.sku = model if model.present?
    modes = Array(data["supported_color_modes"])
    light.supports_color      = modes.include?("rgb")
    light.supports_color_temp = modes.include?("color_temp")
    light.save!
  rescue JSON::ParserError => e
    @logger.warn("GoveeDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def device_id_from(state_topic)
    t = state_topic.to_s
    return nil unless t.start_with?("gv2mqtt/light/") && t.end_with?("/state")
    t.split("/")[2]
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/govee_discovery_handler_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add GoveeDiscoveryHandler to auto-upsert lights from gv2mqtt discovery"
```

---

## Task 6: Collector wiring

Register both handlers unconditionally in the collector (the `govee` config section is removed in Task 7, so drop the `if config.govee` guard now) and require the new handler.

**Files:**
- Modify: `bin/ziwoas_collector`

**Interfaces:**
- Consumes: `GoveeStatusHandler.new(logger:)`, `GoveeDiscoveryHandler.new(logger:)`, `MqttRouter`.

- [ ] **Step 1: Add the require for the discovery handler**

In `bin/ziwoas_collector`, after the line `require "govee_status_handler"`, add:

```ruby
require "govee_discovery_handler"
```

- [ ] **Step 2: Register both handlers unconditionally**

Replace this line:

```ruby
handlers << GoveeStatusHandler.new(topic_prefix: config.govee.topic_prefix, logger: logger) if config.govee
```

with:

```ruby
handlers << GoveeStatusHandler.new(logger: logger)
handlers << GoveeDiscoveryHandler.new(logger: logger)
```

- [ ] **Step 3: Verify the collector boots and wiring is sound**

Run: `bin/rails runner 'require "govee_status_handler"; require "govee_discovery_handler"; h=[GoveeStatusHandler.new(logger: Logger.new(StringIO.new)), GoveeDiscoveryHandler.new(logger: Logger.new(StringIO.new))]; puts h.flat_map(&:subscriptions).inspect'`
Expected output includes: `["gv2mqtt/light/+/state", "gv2mqtt/availability", "gv2mqtt/light/+/config"]`

- [ ] **Step 4: Run the full suite**

Run: `bin/rails test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Wire GoveeStatusHandler + GoveeDiscoveryHandler into the collector"
```

---

## Task 7: Remove the govee config section

gv2mqtt/discovery topics are govee2mqtt conventions encoded as constants, so the `govee:` config section, `build_govee`, `GoveeCfg`, and the `Config#govee` field are removed.

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `config/ziwoas.example.yml`
- Test: `test/config_loader_test.rb`

- [ ] **Step 1: Find govee references in config + tests**

Run: `grep -rn "govee\|Govee" lib/config_loader.rb test/ config/ | grep -iv "govee_status_handler\|govee_discovery_handler\|govee_commander"`
Note every hit; they are removed/updated below.

- [ ] **Step 2: Remove GoveeCfg, build_govee, and the Config#govee field**

In `lib/config_loader.rb`:
- Remove the `GoveeCfg = Struct.new(...)` definition (the `:topic_prefix, :poll_interval_seconds, :command_port, :listen_port` struct).
- Remove `:govee,` from the `Config = Struct.new(...)` field list.
- Remove the line `govee = build_govee(@raw["govee"])` and the `govee:` keyword passed into the `Config.new(...)` constructor.
- Remove the entire `def build_govee(h) ... end` method.

- [ ] **Step 3: Remove the govee block from the example config**

In `config/ziwoas.example.yml`, delete the commented-out govee block (the lines from `# govee:` through `#   listen_port: 4002`, around lines 60–64).

(The real `config/ziwoas.yml` is gitignored: note in the PR that its `govee:` block — `topic_prefix`/`poll_interval_seconds`/`command_port`/`listen_port` — should be deleted on the box too. `config/ziwoas.test.yml` has no govee block.)

- [ ] **Step 4: Remove the govee config-loader tests**

In `test/config_loader_test.rb`, delete these four definitions:
- the `valid_yaml_with_govee` helper method,
- `test_govee_is_nil_without_block`,
- `test_govee_parses_with_defaults`,
- `test_govee_parses_explicit_values`.

- [ ] **Step 5: Verify no lingering references**

Run: `grep -rn "config.govee\|\.govee\b\|build_govee\|GoveeCfg" app lib bin test`
Expected: no matches.

- [ ] **Step 6: Run the full suite**

Run: `bin/rails test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Remove govee config section; gv2mqtt topics are constants now"
```

---

## Task 8: Deployment — native dev binary + prod container + credentials

Dev runs a locally-compiled `govee` binary via a wrapper in `Procfile.dev`; prod runs the ghcr container in docker-compose. Credentials live in a gitignored env file.

**Files:**
- Create: `bin/govee2mqtt`, `config/govee2mqtt.env.example`, `docs/govee2mqtt-setup.md`
- Modify: `Procfile.dev`, `docker-compose.yml`, `.gitignore`

**Interfaces:**
- Produces: a `govee:` Procfile process that launches govee2mqtt with `--hass-discovery-prefix gv2mqtt` and env from `config/govee2mqtt.env`.

- [ ] **Step 1: Create the dev wrapper script**

Create `bin/govee2mqtt`:

```bash
#!/usr/bin/env bash
# Launches a locally-built govee2mqtt for development. Build once per the docs:
#   git clone https://github.com/wez/govee2mqtt vendor/govee2mqtt
#   (cd vendor/govee2mqtt && cargo build --release)
# Override the binary path with GOVEE2MQTT_BIN if you built it elsewhere.
set -euo pipefail

ENV_FILE="config/govee2mqtt.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
else
  echo "bin/govee2mqtt: $ENV_FILE missing — copy config/govee2mqtt.env.example" >&2
  exit 1
fi

BIN="${GOVEE2MQTT_BIN:-vendor/govee2mqtt/target/release/govee}"
if [[ ! -x "$BIN" ]]; then
  echo "bin/govee2mqtt: $BIN not built — see docs/govee2mqtt-setup.md" >&2
  exit 1
fi

exec "$BIN" --hass-discovery-prefix gv2mqtt serve
```

Make it executable:

```bash
chmod +x bin/govee2mqtt
```

- [ ] **Step 2: Point Procfile.dev at the wrapper**

In `Procfile.dev`, replace the line `govee:  ./bin/govee_bridge` with:

```
govee:  ./bin/govee2mqtt
```

- [ ] **Step 3: Create the env example**

Create `config/govee2mqtt.env.example`:

```bash
# Copy to config/govee2mqtt.env (gitignored) and fill in.
# Govee account (needed for room names + cloud scenes/capabilities)
GOVEE_EMAIL=you@example.com
GOVEE_PASSWORD=changeme
# Govee API key (https://developer.govee.com/reference/apply-you-govee-api-key)
GOVEE_API_KEY=00000000-0000-0000-0000-000000000000

# MQTT broker — the same broker ZiWoAS uses
GOVEE_MQTT_HOST=127.0.0.1
GOVEE_MQTT_PORT=1883
#GOVEE_MQTT_USER=
#GOVEE_MQTT_PASSWORD=

GOVEE_TEMPERATURE_SCALE=C
TZ=Europe/Berlin
```

- [ ] **Step 4: Gitignore the secret env and the vendored build**

Append to `.gitignore`:

```
/config/govee2mqtt.env
/vendor/govee2mqtt/
```

- [ ] **Step 5: Add the prod docker-compose service**

In `docker-compose.yml`, add a `govee2mqtt` service under `services:`:

```yaml
  govee2mqtt:
    image: ghcr.io/wez/govee2mqtt:latest
    container_name: govee2mqtt
    restart: unless-stopped
    # Host networking is required for Govee LAN multicast discovery.
    network_mode: host
    command: ["--hass-discovery-prefix", "gv2mqtt", "serve"]
    env_file:
      - config/govee2mqtt.env
    volumes:
      - govee2mqtt_data:/data
```

And add the named volume at the bottom of the file (create a `volumes:` block if none exists):

```yaml
volumes:
  govee2mqtt_data:
```

- [ ] **Step 6: Write the setup doc**

Create `docs/govee2mqtt-setup.md`:

```markdown
# govee2mqtt setup

ZiWoAS delegates all Govee lamp I/O to [`wez/govee2mqtt`](https://github.com/wez/govee2mqtt).

## Credentials
Copy `config/govee2mqtt.env.example` to `config/govee2mqtt.env` (gitignored) and fill in
your Govee email/password, API key, and the MQTT broker host/port.

## Development (native binary)
Build once, pinned to a known tag/commit:

    git clone https://github.com/wez/govee2mqtt vendor/govee2mqtt
    cd vendor/govee2mqtt
    git checkout <tag-or-commit>     # pin; record the value in the PR
    cargo build --release

Then `foreman start` (Procfile.dev) runs `bin/govee2mqtt`, which loads
`config/govee2mqtt.env` and launches `govee --hass-discovery-prefix gv2mqtt serve`.
Override the binary path with `GOVEE2MQTT_BIN` if you built it elsewhere.

Note: govee2mqtt also binds an HTTP port (`--http-port`, default 8056). With host
networking, make sure nothing else uses 8056 (pass `--http-port` in `bin/govee2mqtt`
to change it).

## Production (container)
`docker-compose.yml` runs `ghcr.io/wez/govee2mqtt:latest` with `network_mode: host`
and `env_file: config/govee2mqtt.env`. Bring it up with `docker compose up -d`.
```

- [ ] **Step 7: Verify the wrapper fails cleanly without a build (smoke)**

Run: `GOVEE2MQTT_BIN=/nonexistent bin/govee2mqtt; echo "exit=$?"`
Expected: prints a "not built" message (or the env-missing message if you have not created `config/govee2mqtt.env`) and a non-zero exit. This confirms the guard rails; it is not meant to start the bridge in CI.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Deploy govee2mqtt: native dev wrapper, prod compose service, env template"
```

---

## Task 9: Remove the unused Kamal dependency

Kamal is unused; remove the gem and its config.

**Files:**
- Modify: `Gemfile`, `Gemfile.lock`
- Delete: `config/deploy.yml`, `bin/kamal`, `.kamal/`

- [ ] **Step 1: Confirm Kamal is unreferenced by app code**

Run: `grep -rn "kamal" app lib bin config --include=*.rb -i | grep -iv "bin/kamal"`
Expected: no matches (Kamal is deploy tooling only).

- [ ] **Step 2: Remove the gem**

In `Gemfile`, delete the line:

```ruby
gem "kamal", require: false
```

- [ ] **Step 3: Delete Kamal config + binstub**

```bash
git rm config/deploy.yml bin/kamal
git rm -r .kamal
```

- [ ] **Step 4: Update the lockfile**

Run: `bundle install`
Expected: `Gemfile.lock` no longer lists `kamal`. Verify: `grep -n "^    kamal\| kamal " Gemfile.lock` → no matches.

- [ ] **Step 5: Verify nothing else references Kamal**

Run: `grep -rni "kamal" . --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor`
Expected: no matches (other than possibly historical entries in `docs/superpowers/`).

- [ ] **Step 6: Run the full suite**

Run: `bin/rails test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Remove unused Kamal deployment dependency"
```

---

## Final verification

- [ ] **Full suite green:** `bin/rails test` → all pass.
- [ ] **No stragglers:** `grep -rn "ip_address\|govee/\|GoveeLanClient\|GoveeMqttBridge\|topic_prefix.*govee\|config.govee" app lib bin test` → no matches (the `govee/` check guards against leftover old-topic strings; `gv2mqtt/...` is expected and fine).
- [ ] **Manual smoke (optional, needs real lamps + creds):** build govee2mqtt, fill `config/govee2mqtt.env`, `foreman start`; confirm lamps auto-appear on the Lampen page and toggling on the Schalten tab controls them.
