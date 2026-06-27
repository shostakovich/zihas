# Govee-Lampen (LAN) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Govee-Lampen (on/off, Helligkeit, Farbe, lokale Szenen) im IoT-VLAN über die `/switches`-UI steuerbar machen — Steuerung lokal per Govee-LAN-UDP, gekapselt in einer MQTT↔UDP-Bridge.

**Architecture:** Eine `GoveeMqttBridge` (eigener Prozess) übersetzt MQTT-Befehle in Govee-LAN-UDP und schreibt Gerätestatus zurück nach MQTT. Die Web-App publiziert nur MQTT (via `GoveeCommander`). Ein `MqttRouter` im Collector konsumiert alle eingehenden MQTT-Daten (Shelly + Govee) und dispatcht an Handler, die DB-State schreiben und per ActionCable broadcasten. Lampen sind ein neues, DB-gestütztes Modell mit UI-CRUD.

**Tech Stack:** Ruby on Rails 8.1, `mqtt`-Gem (ruby-mqtt v0.7.0), Rubys Standard-`UDPSocket`, Hotwire/Stimulus + ActionCable, Minitest, SQLite.

## Global Constraints

- Ruby on Rails **8.1**; SQLite; Minitest.
- **Keine neuen Gems.** MQTT über das bestehende `mqtt`-Gem (v0.7.0), UDP über `UDPSocket`.
- Klassennamen/Identifier **englisch**, UI-Texte **deutsch** (bestehende Konvention).
- Commander/Bridges/Clients leben in `lib/`; ActiveRecord-Modelle in `app/models/`; Web-Controller in `app/controllers/`.
- MQTT-Topics: Befehle `govee/<key>/command/<cmd>`, Status `govee/<key>/status`. Shelly bleibt `shellies/...`.
- Govee-`key`: `/[a-z0-9_]+/`, aus `name` generiert, in DB persistiert, danach **stabil**.
- Nach jeder Task: `bin/rails test` grün und `bin/rubocop` sauber. Häufige Commits (ein Commit je Task-Abschluss).
- Baseline vor Beginn: 518 Tests, 0 Fehler.

---

## File Structure

**Modelle (`app/models/`):** `room.rb`, `light.rb`, `light_state.rb`, `preset.rb`, `scene.rb`, `scene_entry.rb`
**Migrationen (`db/migrate/`):** je eine pro Tabelle (`rooms`, `lights`, `light_states`, `presets`, `scenes`, `scene_entries`)
**Transport/Infra (`lib/`):** `govee_lan_client.rb`, `govee_commander.rb`, `plug_commander.rb` (verschoben), `mqtt_router.rb`, `shelly_status_handler.rb`, `govee_status_handler.rb`, `govee_mqtt_bridge.rb`
**Prozess (`bin/`):** `govee_bridge` (neu), `ziwoas_collector` (geändert)
**Config:** `lib/config_loader.rb` (`GoveeCfg` + `build_govee`), `config/ziwoas.example.yml`
**Web-Controller:** `rooms_controller.rb`, `lights_controller.rb`, `light_switches_controller.rb`, `presets_controller.rb`, `scenes_controller.rb`
**View-Model:** `app/models/light_row.rb`
**Views:** `app/views/rooms/*`, `app/views/lights/*`, `app/views/presets/*`, `app/views/scenes/*`, `app/views/switches/_light_card.html.erb`, `_light_head.html.erb`; Erweiterung `app/views/switches/index.html.erb`
**JS:** `app/javascript/controllers/lights_controller.js`
**Routes:** `config/routes.rb`

---

## Task 1: Room model

**Files:**
- Create: `db/migrate/20260624090000_create_rooms.rb`
- Create: `app/models/room.rb`
- Test: `test/models/room_test.rb`

**Interfaces:**
- Produces: `Room` (`has_many :lights`), columns `id`, `name:string` (unique, not null), timestamps.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/room_test.rb
require "test_helper"

class RoomTest < ActiveSupport::TestCase
  test "valid with a name" do
    assert Room.new(name: "Wohnzimmer").valid?
  end

  test "requires a name" do
    refute Room.new(name: "").valid?
  end

  test "name is unique" do
    Room.create!(name: "Küche")
    refute Room.new(name: "Küche").valid?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/room_test.rb`
Expected: FAIL — `uninitialized constant Room` / table missing.

- [ ] **Step 3: Write the migration and model**

```ruby
# db/migrate/20260624090000_create_rooms.rb
class CreateRooms < ActiveRecord::Migration[8.1]
  def change
    create_table :rooms do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :rooms, :name, unique: true
  end
end
```

```ruby
# app/models/room.rb
class Room < ApplicationRecord
  has_many :lights, dependent: :nullify
  validates :name, presence: true, uniqueness: true
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/room_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260624090000_create_rooms.rb app/models/room.rb test/models/room_test.rb db/schema.rb
git commit -m "Add Room model"
```

---

## Task 2: Light model with key generation

**Files:**
- Create: `db/migrate/20260624090100_create_lights.rb`
- Create: `app/models/light.rb`
- Test: `test/models/light_test.rb`

**Interfaces:**
- Consumes: `Room` (Task 1).
- Produces: `Light` with columns `id`, `key:string` (unique, not null), `name:string` (not null), `room_id:bigint` (nullable, FK), `ip_address:string` (not null), `sku:string`, `shelly_plug_id:string`, `supports_color:boolean` (default false), `supports_color_temp:boolean` (default false), timestamps. `belongs_to :room, optional: true`. `to_param` returns `key`. Class method `Light.slugify(name) -> String`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/light_test.rb
require "test_helper"

class LightTest < ActiveSupport::TestCase
  test "valid with name and ip" do
    assert Light.new(name: "Stehlampe", ip_address: "192.168.10.20").valid?
  end

  test "requires name and ip_address" do
    refute Light.new(name: "", ip_address: "").valid?
  end

  test "generates key from name on create" do
    light = Light.create!(name: "Wohnzimmer Stehlampe", ip_address: "192.168.10.20")
    assert_equal "wohnzimmer_stehlampe", light.key
  end

  test "transliterates umlauts in the key" do
    light = Light.create!(name: "Küche Über", ip_address: "192.168.10.21")
    assert_equal "kueche_ueber", light.key
  end

  test "appends a numeric suffix on key collision" do
    Light.create!(name: "Flur", ip_address: "192.168.10.22")
    second = Light.create!(name: "Flur", ip_address: "192.168.10.23")
    assert_equal "flur_2", second.key
  end

  test "key is stable across a rename" do
    light = Light.create!(name: "Diele", ip_address: "192.168.10.24")
    light.update!(name: "Eingang")
    assert_equal "diele", light.key
  end

  test "to_param is the key" do
    light = Light.create!(name: "Bad", ip_address: "192.168.10.25")
    assert_equal "bad", light.to_param
  end

  test "optionally belongs to a room" do
    room  = Room.create!(name: "Salon")
    light = Light.create!(name: "Salon Lampe", ip_address: "192.168.10.26", room: room)
    assert_equal room, light.room
    assert_includes room.lights, light
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/light_test.rb`
Expected: FAIL — `uninitialized constant Light`.

- [ ] **Step 3: Write the migration and model**

```ruby
# db/migrate/20260624090100_create_lights.rb
class CreateLights < ActiveRecord::Migration[8.1]
  def change
    create_table :lights do |t|
      t.string  :key,            null: false
      t.string  :name,           null: false
      t.references :room,        foreign_key: true, null: true
      t.string  :ip_address,     null: false
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

```ruby
# app/models/light.rb
class Light < ApplicationRecord
  UMLAUTS = { "ä" => "ae", "ö" => "oe", "ü" => "ue", "ß" => "ss" }.freeze

  belongs_to :room, optional: true

  validates :name, presence: true
  validates :ip_address, presence: true
  validates :key, presence: true, uniqueness: true,
                  format: { with: /\A[a-z0-9_]+\z/ }

  before_validation :assign_key, on: :create

  def to_param = key

  def self.slugify(name)
    s = name.to_s.downcase
    UMLAUTS.each { |from, to| s = s.gsub(from, to) }
    s.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  end

  private

  def assign_key
    return if key.present?
    base = self.class.slugify(name)
    base = "lamp" if base.empty?
    candidate = base
    counter   = 2
    while self.class.exists?(key: candidate)
      candidate = "#{base}_#{counter}"
      counter  += 1
    end
    self.key = candidate
  end
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/light_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260624090100_create_lights.rb app/models/light.rb test/models/light_test.rb db/schema.rb
git commit -m "Add Light model with slug key generation"
```

---

## Task 3: LightState model

**Files:**
- Create: `db/migrate/20260624090200_create_light_states.rb`
- Create: `app/models/light_state.rb`
- Test: `test/models/light_state_test.rb`

**Interfaces:**
- Produces: `LightState` columns `id`, `light_key:string` (unique, not null), `on:boolean`, `brightness:integer`, `color_r/g/b:integer`, `color_temp_k:integer`, `reachable:boolean`, `last_seen_at:datetime`, timestamps. Class method `LightState.record_state(light_key, attrs) -> Boolean` (true when a visible field changed). `last_seen_at` is always written but does not by itself count as a change.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/light_state_test.rb
require "test_helper"

class LightStateTest < ActiveSupport::TestCase
  setup { LightState.delete_all }

  test "record_state creates a row and returns true" do
    assert LightState.record_state("lamp", on: true, brightness: 50)
    state = LightState.find_by(light_key: "lamp")
    assert_equal true, state.on
    assert_equal 50,   state.brightness
  end

  test "record_state returns false when visible fields are unchanged" do
    LightState.record_state("lamp", on: true, brightness: 50)
    refute LightState.record_state("lamp", on: true, brightness: 50)
  end

  test "record_state returns true and updates on a visible change" do
    LightState.record_state("lamp", on: true, brightness: 50)
    assert LightState.record_state("lamp", on: true, brightness: 80)
    assert_equal 80, LightState.find_by(light_key: "lamp").brightness
    assert_equal 1,  LightState.count
  end

  test "record_state updates last_seen_at even without a visible change" do
    travel_to Time.zone.local(2026, 6, 24, 12, 0) do
      LightState.record_state("lamp", on: true, last_seen_at: Time.current)
    end
    travel_to Time.zone.local(2026, 6, 24, 12, 5) do
      refute LightState.record_state("lamp", on: true, last_seen_at: Time.current)
    end
    assert_equal Time.zone.local(2026, 6, 24, 12, 5),
                 LightState.find_by(light_key: "lamp").last_seen_at
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/light_state_test.rb`
Expected: FAIL — `uninitialized constant LightState`.

- [ ] **Step 3: Write the migration and model**

```ruby
# db/migrate/20260624090200_create_light_states.rb
class CreateLightStates < ActiveRecord::Migration[8.1]
  def change
    create_table :light_states do |t|
      t.string   :light_key, null: false
      t.boolean  :on
      t.integer  :brightness
      t.integer  :color_r
      t.integer  :color_g
      t.integer  :color_b
      t.integer  :color_temp_k
      t.boolean  :reachable
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :light_states, :light_key, unique: true
  end
end
```

```ruby
# app/models/light_state.rb
class LightState < ApplicationRecord
  VISIBLE = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  validates :light_key, presence: true, uniqueness: true

  # Writes the row and returns true when any visible field changed.
  # last_seen_at is always written but is not itself a "visible" change.
  def self.record_state(light_key, attrs)
    attrs = attrs.symbolize_keys
    state = find_or_initialize_by(light_key: light_key)
    changed = VISIBLE.any? { |f| attrs.key?(f) && state[f] != attrs[f] }
    state.assign_attributes(attrs)
    state.save!
    changed
  end
end
```

- [ ] **Step 4: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/light_state_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260624090200_create_light_states.rb app/models/light_state.rb test/models/light_state_test.rb db/schema.rb
git commit -m "Add LightState model with record_state"
```

---

## Task 4: Preset, Scene, SceneEntry models

**Files:**
- Create: `db/migrate/20260624090300_create_presets.rb`
- Create: `db/migrate/20260624090400_create_scenes.rb`
- Create: `db/migrate/20260624090500_create_scene_entries.rb`
- Create: `app/models/preset.rb`, `app/models/scene.rb`, `app/models/scene_entry.rb`
- Test: `test/models/preset_test.rb`, `test/models/scene_test.rb`

**Interfaces:**
- Consumes: `Light` (Task 2).
- Produces:
  - `Preset` columns `id`, `name:string` (not null), `on:boolean` (default true), `brightness:integer`, `color_r/g/b:integer`, `color_temp_k:integer`, timestamps. `has_many :scene_entries`.
  - `Scene` columns `id`, `name:string` (not null), timestamps. `has_many :scene_entries, dependent: :destroy`.
  - `SceneEntry` columns `id`, `scene_id`, `light_id`, `preset_id`, timestamps. `belongs_to :scene`, `belongs_to :light`, `belongs_to :preset`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/models/preset_test.rb
require "test_helper"

class PresetTest < ActiveSupport::TestCase
  test "valid with a name" do
    assert Preset.new(name: "Warm 20%", brightness: 20, color_temp_k: 2700).valid?
  end

  test "requires a name" do
    refute Preset.new(name: "").valid?
  end
end
```

```ruby
# test/models/scene_test.rb
require "test_helper"

class SceneTest < ActiveSupport::TestCase
  setup do
    @light  = Light.create!(name: "Kino Lampe", ip_address: "192.168.10.40")
    @preset = Preset.create!(name: "Warm 20%", brightness: 20, color_temp_k: 2700)
  end

  test "requires a name" do
    refute Scene.new(name: "").valid?
  end

  test "has entries mapping a light to a preset" do
    scene = Scene.create!(name: "Kino")
    scene.scene_entries.create!(light: @light, preset: @preset)
    assert_equal 1, scene.scene_entries.count
    entry = scene.scene_entries.first
    assert_equal @light,  entry.light
    assert_equal @preset, entry.preset
  end

  test "destroying a scene destroys its entries" do
    scene = Scene.create!(name: "Kino")
    scene.scene_entries.create!(light: @light, preset: @preset)
    assert_difference -> { SceneEntry.count }, -1 do
      scene.destroy
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/preset_test.rb test/models/scene_test.rb`
Expected: FAIL — `uninitialized constant Preset` / `Scene`.

- [ ] **Step 3: Write the migrations and models**

```ruby
# db/migrate/20260624090300_create_presets.rb
class CreatePresets < ActiveRecord::Migration[8.1]
  def change
    create_table :presets do |t|
      t.string  :name, null: false
      t.boolean :on, null: false, default: true
      t.integer :brightness
      t.integer :color_r
      t.integer :color_g
      t.integer :color_b
      t.integer :color_temp_k
      t.timestamps
    end
  end
end
```

```ruby
# db/migrate/20260624090400_create_scenes.rb
class CreateScenes < ActiveRecord::Migration[8.1]
  def change
    create_table :scenes do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end
```

```ruby
# db/migrate/20260624090500_create_scene_entries.rb
class CreateSceneEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :scene_entries do |t|
      t.references :scene,  null: false, foreign_key: true
      t.references :light,  null: false, foreign_key: true
      t.references :preset, null: false, foreign_key: true
      t.timestamps
    end
  end
end
```

```ruby
# app/models/preset.rb
class Preset < ApplicationRecord
  has_many :scene_entries, dependent: :restrict_with_error
  validates :name, presence: true
end
```

```ruby
# app/models/scene.rb
class Scene < ApplicationRecord
  has_many :scene_entries, dependent: :destroy
  validates :name, presence: true
end
```

```ruby
# app/models/scene_entry.rb
class SceneEntry < ApplicationRecord
  belongs_to :scene
  belongs_to :light
  belongs_to :preset
end
```

- [ ] **Step 4: Migrate and run the tests**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/preset_test.rb test/models/scene_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add db/migrate/2026062409030*_*.rb db/migrate/20260624090400_create_scenes.rb db/migrate/20260624090500_create_scene_entries.rb app/models/preset.rb app/models/scene.rb app/models/scene_entry.rb test/models/preset_test.rb test/models/scene_test.rb db/schema.rb
git commit -m "Add Preset, Scene, SceneEntry models"
```

---

## Task 5: GoveeCfg config section

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `config/ziwoas.example.yml`
- Test: `test/config_loader_test.rb`

**Interfaces:**
- Produces: `ConfigLoader::GoveeCfg` (`Struct` with `topic_prefix`, `poll_interval_seconds`, `command_port`, `listen_port`). `Config#govee` returns a `GoveeCfg` or `nil` when no `govee:` block is present. Defaults: `topic_prefix: "govee"`, `poll_interval_seconds: 30`, `command_port: 4003`, `listen_port: 4002`.

- [ ] **Step 1: Write the failing tests**

```ruby
# append inside class ConfigLoaderTest in test/config_loader_test.rb

  def valid_yaml_with_govee
    valid_yaml + <<~YAML
      govee:
        topic_prefix: govee
        poll_interval_seconds: 15
        command_port: 4003
        listen_port: 4002
    YAML
  end

  def test_govee_is_nil_without_block
    assert_nil load_yaml(valid_yaml).govee
  end

  def test_govee_parses_with_defaults
    cfg = load_yaml(valid_yaml + "govee:\n").govee
    assert_equal "govee", cfg.topic_prefix
    assert_equal 30,      cfg.poll_interval_seconds
    assert_equal 4003,    cfg.command_port
    assert_equal 4002,    cfg.listen_port
  end

  def test_govee_parses_explicit_values
    cfg = load_yaml(valid_yaml_with_govee).govee
    assert_equal 15, cfg.poll_interval_seconds
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/config_loader_test.rb -n "/govee/"`
Expected: FAIL — `NoMethodError: undefined method 'govee'`.

- [ ] **Step 3: Implement GoveeCfg and build_govee**

In `lib/config_loader.rb`, add the struct next to the others:

```ruby
  GoveeCfg = Struct.new(:topic_prefix, :poll_interval_seconds, :command_port,
                        :listen_port, keyword_init: true)
```

Add `:govee` to the `Config` struct members (append after `:solakon`):

```ruby
  Config = Struct.new(:electricity_price_eur_per_kwh, :timezone,
                      :mqtt, :fritz_poll, :plugs, :fritz_box, :weather,
                      :switchbot, :sensors, :trmnl, :solakon, :govee,
                      keyword_init: true)
```

In `#build`, add `govee = build_govee(@raw["govee"])` next to the other builders and pass `govee: govee` into `Config.new(...)`.

Add the builder (mirrors `build_solakon`):

```ruby
  def build_govee(h)
    return nil unless @raw.key?("govee")
    h = h.nil? ? {} : require_hash(h, "govee")
    GoveeCfg.new(
      topic_prefix:          (h["topic_prefix"] || "govee").to_s,
      poll_interval_seconds: (h["poll_interval_seconds"] || 30).to_i,
      command_port:          (h["command_port"] || 4003).to_i,
      listen_port:           (h["listen_port"] || 4002).to_i,
    )
  end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/config_loader_test.rb`
Expected: PASS (all config tests, including the 3 new ones).

- [ ] **Step 5: Document the block and commit**

Append to `config/ziwoas.example.yml`:

```yaml

# Govee-Lampen (lokale LAN-Steuerung über die Bridge).
# Ohne diesen Block ist die Govee-Bridge aus. Leerer Block = Defaults.
# govee:
#   topic_prefix: govee
#   poll_interval_seconds: 30
#   command_port: 4003
#   listen_port: 4002
```

```bash
git add lib/config_loader.rb config/ziwoas.example.yml test/config_loader_test.rb
git commit -m "Add govee config section to ConfigLoader"
```

---

## Task 6: GoveeLanClient (UDP protocol)

**Files:**
- Create: `lib/govee_lan_client.rb`
- Test: `test/govee_lan_client_test.rb`

**Interfaces:**
- Produces: `GoveeLanClient.new(socket_factory: -> { UDPSocket.new })`.
  - `#turn(ip, on)` / `#brightness(ip, value)` / `#color(ip, r:, g:, b:)` / `#color_temp(ip, kelvin)` / `#request_status(ip)` — each serializes one Govee-LAN JSON message and sends it via UDP to `ip:4003`.
  - `GoveeLanClient.parse_status(payload) -> Status | nil`, where `Status = Struct.new(:on, :brightness, :color_r, :color_g, :color_b, :color_temp_k, :sku, keyword_init: true)`.
  - `GoveeLanClient::COMMAND_PORT = 4003`.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/govee_lan_client_test.rb
require "test_helper"
require "govee_lan_client"

class GoveeLanClientTest < ActiveSupport::TestCase
  class FakeSocket
    attr_reader :sent, :closed
    def initialize(bucket) = (@bucket = bucket; @closed = false)
    def send(msg, _flags, host, port) = @bucket << { msg: msg, host: host, port: port }
    def close = @closed = true
  end

  def client_with(bucket)
    GoveeLanClient.new(socket_factory: -> { FakeSocket.new(bucket) })
  end

  test "turn on sends the turn command to port 4003" do
    sent = []
    client_with(sent).turn("192.168.10.20", true)
    assert_equal 1, sent.length
    assert_equal "192.168.10.20", sent.first[:host]
    assert_equal 4003,            sent.first[:port]
    assert_equal({ "msg" => { "cmd" => "turn", "data" => { "value" => 1 } } },
                 JSON.parse(sent.first[:msg]))
  end

  test "turn off serializes value 0" do
    sent = []
    client_with(sent).turn("192.168.10.20", false)
    assert_equal 0, JSON.parse(sent.first[:msg]).dig("msg", "data", "value")
  end

  test "brightness serializes the value" do
    sent = []
    client_with(sent).brightness("192.168.10.20", 42)
    msg = JSON.parse(sent.first[:msg])["msg"]
    assert_equal "brightness", msg["cmd"]
    assert_equal 42, msg.dig("data", "value")
  end

  test "color serializes rgb with colorTemInKelvin 0" do
    sent = []
    client_with(sent).color("192.168.10.20", r: 255, g: 100, b: 0)
    data = JSON.parse(sent.first[:msg]).dig("msg", "data")
    assert_equal({ "r" => 255, "g" => 100, "b" => 0 }, data["color"])
    assert_equal 0, data["colorTemInKelvin"]
  end

  test "color_temp serializes the kelvin value" do
    sent = []
    client_with(sent).color_temp("192.168.10.20", 3000)
    assert_equal 3000, JSON.parse(sent.first[:msg]).dig("msg", "data", "colorTemInKelvin")
  end

  test "request_status sends devStatus" do
    sent = []
    client_with(sent).request_status("192.168.10.20")
    assert_equal "devStatus", JSON.parse(sent.first[:msg]).dig("msg", "cmd")
  end

  test "closes the socket after sending" do
    socket = nil
    GoveeLanClient.new(socket_factory: -> { socket = FakeSocket.new([]) })
                  .turn("192.168.10.20", true)
    assert socket.closed
  end

  test "parse_status maps a devStatus response" do
    payload = JSON.generate("msg" => { "cmd" => "devStatus", "data" => {
      "onOff" => 1, "brightness" => 60,
      "color" => { "r" => 10, "g" => 20, "b" => 30 },
      "colorTemInKelvin" => 0, "sku" => "H6076"
    } })
    s = GoveeLanClient.parse_status(payload)
    assert_equal true, s.on
    assert_equal 60,   s.brightness
    assert_equal 30,   s.color_b
    assert_equal "H6076", s.sku
  end

  test "parse_status returns nil for malformed payload" do
    assert_nil GoveeLanClient.parse_status("not-json{")
    assert_nil GoveeLanClient.parse_status(JSON.generate("foo" => 1))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/govee_lan_client_test.rb`
Expected: FAIL — `cannot load such file -- govee_lan_client`.

- [ ] **Step 3: Implement the client**

```ruby
# lib/govee_lan_client.rb
require "json"
require "socket"

# Pure Govee LAN protocol: serialize commands, send unicast UDP to :4003,
# parse devStatus responses. No MQTT, no DB. Socket is injectable for tests.
class GoveeLanClient
  COMMAND_PORT = 4003

  Status = Struct.new(:on, :brightness, :color_r, :color_g, :color_b,
                      :color_temp_k, :sku, keyword_init: true)

  def initialize(socket_factory: -> { UDPSocket.new })
    @socket_factory = socket_factory
  end

  def turn(ip, on)           = send_command(ip, "turn",       { "value" => on ? 1 : 0 })
  def brightness(ip, value)  = send_command(ip, "brightness", { "value" => value.to_i })
  def request_status(ip)     = send_command(ip, "devStatus",  {})

  def color(ip, r:, g:, b:)
    send_command(ip, "colorwc",
                 { "color" => { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i },
                   "colorTemInKelvin" => 0 })
  end

  def color_temp(ip, kelvin)
    send_command(ip, "colorwc",
                 { "color" => { "r" => 0, "g" => 0, "b" => 0 },
                   "colorTemInKelvin" => kelvin.to_i })
  end

  def self.parse_status(payload)
    data = JSON.parse(payload).dig("msg", "data")
    return nil unless data.is_a?(Hash) && data.key?("onOff")
    color = data["color"] || {}
    Status.new(
      on:           data["onOff"] == 1,
      brightness:   data["brightness"],
      color_r:      color["r"],
      color_g:      color["g"],
      color_b:      color["b"],
      color_temp_k: data["colorTemInKelvin"],
      sku:          data["sku"],
    )
  rescue JSON::ParserError
    nil
  end

  private

  def send_command(ip, cmd, data)
    socket = @socket_factory.call
    socket.send(JSON.generate("msg" => { "cmd" => cmd, "data" => data }), 0, ip, COMMAND_PORT)
  ensure
    begin; socket&.close; rescue StandardError; nil; end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/govee_lan_client_test.rb`
Expected: PASS (10 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/govee_lan_client.rb test/govee_lan_client_test.rb
git commit -m "Add GoveeLanClient UDP protocol layer"
```

---

## Task 7: Move PlugCommander to lib/

**Files:**
- Move: `app/models/plug_commander.rb` → `lib/plug_commander.rb`
- Move: `test/models/plug_commander_test.rb` → `test/plug_commander_test.rb`

**Interfaces:**
- Produces: `PlugCommander` unchanged, now living in `lib/`. `config.autoload_lib(ignore: %w[assets tasks])` (see `config/application.rb`) keeps it autoloadable by Zeitwerk under the exact same constant name, so its consumers — `app/controllers/plug_switches_controller.rb` and `app/jobs/schedule_tick_job.rb` — need **no** code change.

- [ ] **Step 1: Move the source and test with git**

```bash
git mv app/models/plug_commander.rb lib/plug_commander.rb
git mv test/models/plug_commander_test.rb test/plug_commander_test.rb
```

- [ ] **Step 2: Add the subject require to the moved test**

Lib-class tests in this repo require their subject explicitly (e.g. `test/config_loader_test.rb`). At the top of `test/plug_commander_test.rb` add the third line:

```ruby
require "test_helper"
require "config_loader"
require "plug_commander"
```

- [ ] **Step 3: Run the moved test**

Run: `bin/rails test test/plug_commander_test.rb`
Expected: PASS — Zeitwerk autoloads `lib/plug_commander.rb` as `PlugCommander`.

- [ ] **Step 4: Confirm both consumers still work (no edits needed)**

The controller and the scheduler job reference `PlugCommander` via autoload; moving the file between two autoloaded roots is transparent. Verify:

Run: `bin/rails test test/controllers/plug_switches_controller_test.rb test/jobs/schedule_tick_job_test.rb`
Expected: PASS (both green, no source changes).

- [ ] **Step 5: Full suite + commit**

Run: `bin/rails test`
Expected: PASS (same count as baseline, file relocated).

```bash
git add -A
git commit -m "Move PlugCommander to lib/ (transport layer)"
```

---

## Task 8: GoveeCommander (MQTT publish)

**Files:**
- Create: `lib/govee_commander.rb`
- Test: `test/govee_commander_test.rb`

**Interfaces:**
- Consumes: `Light` (Task 2), `ConfigLoader::MqttCfg`.
- Produces: `GoveeCommander` with class methods, each opening a short-lived MQTT connection (mirrors `PlugCommander`):
  - `turn(light, on:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)`
  - `set_brightness(light, value:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)`
  - `set_color(light, r:, g:, b:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)`
  - `set_color_temp(light, kelvin:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)`
  - `refresh(light, mqtt_config:, topic_prefix:, mqtt_factory: nil)`
  - Publishes `"<prefix>/<key>/command/<cmd>"` with JSON payloads: `turn`→`{"on":bool}`, `brightness`→`{"value":int}`, `color`→`{"r":int,"g":int,"b":int}`, `color_temp`→`{"temp_k":int}`, `refresh`→`{}`.
  - Raises `GoveeCommander::Error` on publish failure. Does **not** persist a log row.

- [ ] **Step 1: Write the failing tests**

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
    @light = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")
  end

  def opts(client)
    { mqtt_config: @mqtt_config, topic_prefix: "govee", mqtt_factory: -> { client } }
  end

  test "turn publishes to the command topic with a boolean payload" do
    c = FakeMqtt.new
    GoveeCommander.turn(@light, on: true, source: :manual, **opts(c))
    topic, payload = c.published.first
    assert_equal "govee/stehlampe/command/turn", topic
    assert_equal({ "on" => true }, JSON.parse(payload))
    assert c.disconnected
  end

  test "set_brightness publishes a value payload" do
    c = FakeMqtt.new
    GoveeCommander.set_brightness(@light, value: 42, source: :manual, **opts(c))
    topic, payload = c.published.first
    assert_equal "govee/stehlampe/command/brightness", topic
    assert_equal({ "value" => 42 }, JSON.parse(payload))
  end

  test "set_color publishes rgb" do
    c = FakeMqtt.new
    GoveeCommander.set_color(@light, r: 255, g: 100, b: 0, source: :manual, **opts(c))
    topic, payload = c.published.first
    assert_equal "govee/stehlampe/command/color", topic
    assert_equal({ "r" => 255, "g" => 100, "b" => 0 }, JSON.parse(payload))
  end

  test "set_color_temp publishes temp_k" do
    c = FakeMqtt.new
    GoveeCommander.set_color_temp(@light, kelvin: 3000, source: :manual, **opts(c))
    assert_equal "govee/stehlampe/command/color_temp", c.published.first[0]
    assert_equal({ "temp_k" => 3000 }, JSON.parse(c.published.first[1]))
  end

  test "refresh publishes an empty payload" do
    c = FakeMqtt.new
    GoveeCommander.refresh(@light, **opts(c).except(:mqtt_factory).merge(mqtt_factory: -> { c }))
    assert_equal "govee/stehlampe/command/refresh", c.published.first[0]
    assert_equal({}, JSON.parse(c.published.first[1]))
  end

  test "publish failure raises GoveeCommander::Error" do
    c = FakeMqtt.new(fail_connect: true)
    assert_raises(GoveeCommander::Error) do
      GoveeCommander.turn(@light, on: true, source: :manual, **opts(c))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/govee_commander_test.rb`
Expected: FAIL — `cannot load such file -- govee_commander`.

- [ ] **Step 3: Implement the commander**

```ruby
# lib/govee_commander.rb
require "mqtt"
require "json"

# Web-side choke point for Govee commands. Publishes over a short-lived MQTT
# connection; the GoveeMqttBridge translates these to UDP. Mirrors PlugCommander
# but does not persist a command log (LightState is the record of truth).
class GoveeCommander
  class Error < StandardError; end

  def self.turn(light, on:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "turn", { "on" => !!on })
  end

  def self.set_brightness(light, value:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "brightness", { "value" => value.to_i })
  end

  def self.set_color(light, r:, g:, b:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "color", { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i })
  end

  def self.set_color_temp(light, kelvin:, source:, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "color_temp", { "temp_k" => kelvin.to_i })
  end

  def self.refresh(light, mqtt_config:, topic_prefix:, mqtt_factory: nil)
    new(mqtt_config: mqtt_config, topic_prefix: topic_prefix, mqtt_factory: mqtt_factory)
      .publish(light, "refresh", {})
  end

  def initialize(mqtt_config:, topic_prefix:, mqtt_factory: nil)
    @mqtt_config  = mqtt_config
    @topic_prefix = topic_prefix
    @mqtt_factory = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
  end

  def publish(light, cmd, payload)
    client = @mqtt_factory.call
    begin
      client.connect
      client.publish("#{@topic_prefix}/#{light.key}/command/#{cmd}", JSON.generate(payload))
    rescue StandardError => e
      raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/govee_commander_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/govee_commander.rb test/govee_commander_test.rb
git commit -m "Add GoveeCommander MQTT publisher"
```

---

## Task 9: MqttRouter + ShellyStatusHandler (refactor MqttSubscriber)

**Files:**
- Create: `lib/mqtt_router.rb`
- Create: `lib/shelly_status_handler.rb`
- Delete: `lib/mqtt_subscriber.rb`
- Move/rewrite test: `test/mqtt_subscriber_test.rb` → `test/shelly_status_handler_test.rb`
- Create: `test/mqtt_router_test.rb`

**Interfaces:**
- Produces:
  - `ShellyStatusHandler.new(mqtt_config:, plugs:, logger:, clock: -> { Time.now.to_f })` with `#subscriptions -> Array<String>`, `#matches?(topic) -> Boolean`, `#handle(topic, payload)`. Behavior identical to the old `MqttSubscriber#handle_message`/`#accumulate` (Sample insert, PlugState.record_output, batched "dashboard" broadcast every 5s).
  - `MqttRouter.new(mqtt_config:, handlers:, logger:)` with `#run` (backoff/reconnect loop), `#stop!`, and `#dispatch(topic, payload)` (routes to the first handler whose `matches?` is true; warns if none).

- [ ] **Step 1: Create the ShellyStatusHandler test (rewrite of subscriber test)**

```bash
git mv test/mqtt_subscriber_test.rb test/shelly_status_handler_test.rb
```

Replace its head and class name; the body of the test methods is unchanged except for constructing the handler and calling `handle` instead of `handle_message`:

```ruby
# test/shelly_status_handler_test.rb — header
require "test_helper"
require "shelly_status_handler"
require "config_loader"
require "logger"
require "stringio"

class ShellyStatusHandlerTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    PlugState.delete_all
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)
    @now    = 1_700_000_000.0
    @mqtt_config = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",   name: "Solar",  role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    ]
    @handler = ShellyStatusHandler.new(
      mqtt_config: @mqtt_config, plugs: @plugs, logger: @logger, clock: -> { @now }
    )
  end
```

Then in every existing test body, replace `@subscriber.handle_message(` with `@handler.handle(`. Keep `status_payload` and `capture_broadcasts` helpers as-is. Add two new tests:

```ruby
  test "subscriptions targets the shelly status topic" do
    assert_equal [ "shellies/+/status/switch:0" ], @handler.subscriptions
  end

  test "matches only shellies topics" do
    assert @handler.matches?("shellies/bkw/status/switch:0")
    refute @handler.matches?("govee/lamp/status")
  end
```

- [ ] **Step 2: Create the MqttRouter test**

```ruby
# test/mqtt_router_test.rb
require "test_helper"
require "mqtt_router"
require "config_loader"
require "logger"
require "stringio"

class MqttRouterTest < ActiveSupport::TestCase
  class FakeHandler
    attr_reader :handled
    def initialize(prefix) = (@prefix = prefix; @handled = [])
    def subscriptions = [ "#{@prefix}/#" ]
    def matches?(topic) = topic.start_with?("#{@prefix}/")
    def handle(topic, payload) = @handled << [ topic, payload ]
  end

  setup do
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)
    @mqtt_config = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
  end

  test "dispatch routes a topic to the matching handler" do
    shelly = FakeHandler.new("shellies")
    govee  = FakeHandler.new("govee")
    router = MqttRouter.new(mqtt_config: @mqtt_config, handlers: [ shelly, govee ], logger: @logger)

    router.dispatch("govee/lamp/status", "payload")

    assert_equal [], shelly.handled
    assert_equal [ [ "govee/lamp/status", "payload" ] ], govee.handled
  end

  test "dispatch warns when no handler matches" do
    router = MqttRouter.new(mqtt_config: @mqtt_config, handlers: [ FakeHandler.new("shellies") ], logger: @logger)
    router.dispatch("unknown/topic", "x")
    assert_match(/no handler/i, @log_io.string)
  end
end
```

- [ ] **Step 3: Run both tests to verify they fail**

Run: `bin/rails test test/shelly_status_handler_test.rb test/mqtt_router_test.rb`
Expected: FAIL — `cannot load such file -- shelly_status_handler` / `mqtt_router`.

- [ ] **Step 4: Implement the handler and router, delete the old subscriber**

```ruby
# lib/shelly_status_handler.rb
require "json"

# Consumes Shelly (and Fritz-via-bridge) status messages on the shellies topic:
# inserts Sample rows, records PlugState output, and batches a "dashboard"
# ActionCable broadcast. Extracted verbatim from the former MqttSubscriber.
class ShellyStatusHandler
  BROADCAST_INTERVAL = 5

  def initialize(mqtt_config:, plugs:, logger:, clock: -> { Time.now.to_f })
    @mqtt_config       = mqtt_config
    @plug_map          = plugs.to_h { |p| [ p.id, p ] }
    @logger            = logger
    @clock             = clock
    @buckets           = {}
    @pending           = {}
    @last_broadcast_at = 0
  end

  def subscriptions = [ "#{@mqtt_config.topic_prefix}/+/status/switch:0" ]

  def matches?(topic) = topic.start_with?("#{@mqtt_config.topic_prefix}/")

  def handle(topic, payload)
    plug_id = topic.split("/")[@mqtt_config.topic_prefix.split("/").length]
    plug    = @plug_map[plug_id]
    unless plug
      @logger.warn("ShellyStatusHandler: unknown plug '#{plug_id}' on topic #{topic}")
      return
    end

    data       = JSON.parse(payload)
    apower_w   = data["apower"].to_f
    aenergy_wh = data.dig("aenergy", "total").to_f
    output     = data["output"]
    ts         = @clock.call.to_i

    Sample.create!(plug_id: plug_id, ts: ts, apower_w: apower_w, aenergy_wh: aenergy_wh)
    PlugState.record_output(plug_id, output) unless output.nil?
    @logger.debug("ShellyStatusHandler: #{plug_id} #{apower_w} W / #{aenergy_wh} Wh")
    accumulate(plug, ts, apower_w, aenergy_wh, output)
  rescue ActiveRecord::RecordNotUnique
    # duplicate ts within same second — skip silently
  rescue ActiveRecord::RecordInvalid => e
    @logger.warn("ShellyStatusHandler: invalid output on #{topic}: #{e.message}")
  rescue JSON::ParserError => e
    @logger.warn("ShellyStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def accumulate(plug, ts, apower_w, aenergy_wh, output = nil)
    bucket_ts = (ts / 60) * 60
    bucket    = @buckets[plug.id]
    if bucket && bucket[:bucket_ts] == bucket_ts
      bucket[:sum]   += apower_w
      bucket[:count] += 1
    else
      @buckets[plug.id] = { bucket_ts: bucket_ts, sum: apower_w, count: 1 }
      bucket = @buckets[plug.id]
    end
    avg_power_w = bucket[:sum].to_f / bucket[:count]

    @pending[plug.id] = {
      plug_id: plug.id, name: plug.name, role: plug.role.to_s, online: true,
      ts: ts, bucket_ts: bucket_ts, apower_w: apower_w, avg_power_w: avg_power_w,
      aenergy_wh: aenergy_wh, output: output
    }

    now = @clock.call
    return unless now - @last_broadcast_at >= BROADCAST_INTERVAL

    ActionCable.server.broadcast("dashboard", { ts: now.to_i, plugs: @pending.values })
    @pending.clear
    @last_broadcast_at = now
  rescue => e
    @logger.warn("ShellyStatusHandler: ActionCable broadcast failed: #{e.message}")
  end
end
```

```ruby
# lib/mqtt_router.rb
require "mqtt"

# One MQTT connection that subscribes to the union of all handler patterns and
# dispatches each message to the handler whose #matches? returns true.
# Backoff/reconnect loop lives here (extracted from the former MqttSubscriber).
class MqttRouter
  def initialize(mqtt_config:, handlers:, logger:)
    @mqtt_config = mqtt_config
    @handlers    = handlers
    @logger      = logger
    @stopping    = false
  end

  def run
    backoff = 1
    until @stopping
      begin
        connect_and_run
        backoff = 1
      rescue => e
        @logger.error("MqttRouter: #{e.class}: #{e.message}")
        sleep([ backoff, 60 ].min) unless @stopping
        backoff = [ backoff * 2, 60 ].min
      end
    end
  end

  def stop!
    @stopping = true
    begin; @client&.disconnect; rescue StandardError; nil; end
  end

  def dispatch(topic, payload)
    handler = @handlers.find { |h| h.matches?(topic) }
    return @logger.warn("MqttRouter: no handler for #{topic}") unless handler
    handler.handle(topic, payload)
  end

  private

  def connect_and_run
    @client = MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    @client.connect
    topics = @handlers.flat_map(&:subscriptions).uniq
    topics.each { |t| @client.subscribe(t) }
    @logger.info("MqttRouter: connected to #{@mqtt_config.host}:#{@mqtt_config.port}, subscribed #{topics.join(', ')}")
    @client.get { |t, payload| dispatch(t, payload) }
  ensure
    begin; @client&.disconnect; rescue StandardError; nil; end
  end
end
```

```bash
git rm lib/mqtt_subscriber.rb
```

- [ ] **Step 5: Run tests, then full suite, then commit**

Run: `bin/rails test test/shelly_status_handler_test.rb test/mqtt_router_test.rb`
Expected: PASS.

Run: `bin/rails test`
Expected: FAIL only in `bin/ziwoas_collector` references (not a test) — the suite itself should be green since nothing else requires `mqtt_subscriber`. If any file still references `MqttSubscriber`, it is `bin/ziwoas_collector` (fixed in Task 12). Confirm with: `grep -rn "mqtt_subscriber\|MqttSubscriber" app lib test` → only `bin/ziwoas_collector` remains.

```bash
git add -A
git commit -m "Refactor MqttSubscriber into MqttRouter + ShellyStatusHandler"
```

---

## Task 10: GoveeStatusHandler

**Files:**
- Create: `lib/govee_status_handler.rb`
- Test: `test/govee_status_handler_test.rb`

**Interfaces:**
- Consumes: `LightState` (Task 3), `Light` (Task 2).
- Produces: `GoveeStatusHandler.new(topic_prefix:, logger:)` with `#subscriptions -> ["<prefix>/+/status"]`, `#matches?(topic)`, `#handle(topic, payload)`. On a valid `govee/<key>/status` message it writes `LightState.record_state(key, ...)`, fills `Light#sku` when the payload carries one (auto-detection from the first devStatus), and broadcasts `{ lights: [state_hash] }` on the `"dashboard"` ActionCable stream. Status payload JSON keys: `on`, `brightness`, `color_r`, `color_g`, `color_b`, `color_temp_k`, `reachable`, `sku`.

- [ ] **Step 1: Write the failing tests**

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
    @handler = GoveeStatusHandler.new(topic_prefix: "govee", logger: Logger.new(@log_io))
  end

  def payload(overrides = {})
    JSON.generate({ "on" => true, "brightness" => 60, "color_r" => 10, "color_g" => 20,
                    "color_b" => 30, "color_temp_k" => 0, "reachable" => true }.merge(overrides))
  end

  def capture_broadcasts
    broadcasts = []
    server = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, data| broadcasts << [ stream, data ] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "subscriptions targets govee status topics" do
    assert_equal [ "govee/+/status" ], @handler.subscriptions
  end

  test "matches only govee status topics" do
    assert @handler.matches?("govee/lamp/status")
    refute @handler.matches?("shellies/bkw/status/switch:0")
  end

  test "handle writes LightState from the payload" do
    @handler.handle("govee/lamp/status", payload)
    state = LightState.find_by(light_key: "lamp")
    assert_equal true, state.on
    assert_equal 60,   state.brightness
    assert_equal 30,   state.color_b
    assert_equal true, state.reachable
  end

  test "handle broadcasts the light state on the dashboard stream" do
    capture_broadcasts do |broadcasts|
      @handler.handle("govee/lamp/status", payload)
      stream, data = broadcasts.first
      assert_equal "dashboard", stream
      assert_equal "lamp", data[:lights].first[:light_key]
      assert_equal 60,     data[:lights].first[:brightness]
    end
  end

  test "handle fills the light sku when present" do
    Light.create!(name: "Lampe", key: "lamp", ip_address: "192.168.10.20")
    @handler.handle("govee/lamp/status", payload("sku" => "H6076"))
    assert_equal "H6076", Light.find_by(key: "lamp").sku
  end

  test "handle ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("govee/lamp/status", "not-json{") }
    assert_equal 0, LightState.count
    assert_match(/invalid json/i, @log_io.string)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/govee_status_handler_test.rb`
Expected: FAIL — `cannot load such file -- govee_status_handler`.

- [ ] **Step 3: Implement the handler**

```ruby
# lib/govee_status_handler.rb
require "json"

# Consumes govee/<key>/status messages: upserts LightState and broadcasts the
# new state to the switches page over the "dashboard" ActionCable stream.
class GoveeStatusHandler
  FIELDS = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  def initialize(topic_prefix:, logger:)
    @topic_prefix = topic_prefix
    @logger       = logger
  end

  def subscriptions = [ "#{@topic_prefix}/+/status" ]

  def matches?(topic)
    topic.start_with?("#{@topic_prefix}/") && topic.end_with?("/status")
  end

  def handle(topic, payload)
    key  = topic.split("/")[1]
    data = JSON.parse(payload)
    attrs = FIELDS.to_h { |f| [ f, data[f.to_s] ] }
    attrs[:last_seen_at] = Time.current
    LightState.record_state(key, attrs)
    fill_sku(key, data["sku"])
    broadcast(key, attrs)
  rescue JSON::ParserError => e
    @logger.warn("GoveeStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def fill_sku(key, sku)
    return if sku.blank?
    Light.where(key: key, sku: nil).update_all(sku: sku)
  end

  def broadcast(key, attrs)
    ActionCable.server.broadcast("dashboard", { lights: [ attrs.slice(*FIELDS).merge(light_key: key) ] })
  rescue => e
    @logger.warn("GoveeStatusHandler: ActionCable broadcast failed: #{e.message}")
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/govee_status_handler_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/govee_status_handler.rb test/govee_status_handler_test.rb
git commit -m "Add GoveeStatusHandler"
```

---

## Task 11: GoveeMqttBridge + bin/govee_bridge

**Files:**
- Create: `lib/govee_mqtt_bridge.rb`
- Create: `bin/govee_bridge`
- Test: `test/govee_mqtt_bridge_test.rb`

**Interfaces:**
- Consumes: `GoveeLanClient` (Task 6), `Light` (Task 2), `ConfigLoader::MqttCfg` + `GoveeCfg`.
- Produces: `GoveeMqttBridge.new(mqtt_config:, govee_config:, logger:, lan_client: GoveeLanClient.new, lights_provider: -> { Light.all }, mqtt_factory: nil)` with testable methods:
  - `#handle_command(topic, payload)` — parses `govee/<key>/command/<cmd>`, looks up the light by key via `lights_provider`, calls the matching `lan_client` method, then `lan_client.request_status(ip)`. On `refresh`, re-reads `lights_provider` first.
  - `#handle_datagram(payload, sender_ip)` — `GoveeLanClient.parse_status`, finds the light whose `ip_address == sender_ip`, publishes `govee/<key>/status` JSON (`on`, `brightness`, `color_r/g/b`, `color_temp_k`, `reachable: true`, `sku`) via a persistent MQTT client.
  - `#poll_once` — sends `request_status` to every light ip.
  - `#run` / `#stop!` — wire command-consumer + UDP listener (`:listen_port`) + poller threads.

- [ ] **Step 1: Write the failing tests**

```ruby
# test/govee_mqtt_bridge_test.rb
require "test_helper"
require "govee_mqtt_bridge"
require "config_loader"
require "logger"
require "stringio"

class GoveeMqttBridgeTest < ActiveSupport::TestCase
  class FakeLan
    attr_reader :calls
    def initialize = @calls = []
    def turn(ip, on)            = @calls << [ :turn, ip, on ]
    def brightness(ip, value)   = @calls << [ :brightness, ip, value ]
    def color(ip, r:, g:, b:)   = @calls << [ :color, ip, r, g, b ]
    def color_temp(ip, kelvin)  = @calls << [ :color_temp, ip, kelvin ]
    def request_status(ip)      = @calls << [ :request_status, ip ]
  end

  class FakeMqtt
    attr_reader :published
    def initialize = @published = []
    def connect = nil
    def disconnect = nil
    def publish(topic, payload) = @published << [ topic, payload ]
  end

  setup do
    Light.delete_all
    @light = Light.create!(name: "Stehlampe", key: "stehlampe", ip_address: "192.168.10.20")
    @mqtt_config  = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @govee_config = ConfigLoader::GoveeCfg.new(topic_prefix: "govee", poll_interval_seconds: 30,
                                               command_port: 4003, listen_port: 4002)
    @lan  = FakeLan.new
    @mqtt = FakeMqtt.new
    @bridge = GoveeMqttBridge.new(
      mqtt_config: @mqtt_config, govee_config: @govee_config,
      logger: Logger.new(StringIO.new), lan_client: @lan,
      lights_provider: -> { Light.all.to_a }, mqtt_factory: -> { @mqtt }
    )
  end

  test "handle_command turn sends LAN turn then requests status" do
    @bridge.handle_command("govee/stehlampe/command/turn", JSON.generate("on" => true))
    assert_equal [ :turn, "192.168.10.20", true ], @lan.calls[0]
    assert_equal [ :request_status, "192.168.10.20" ], @lan.calls[1]
  end

  test "handle_command brightness forwards the value" do
    @bridge.handle_command("govee/stehlampe/command/brightness", JSON.generate("value" => 42))
    assert_equal [ :brightness, "192.168.10.20", 42 ], @lan.calls[0]
  end

  test "handle_command color forwards rgb" do
    @bridge.handle_command("govee/stehlampe/command/color", JSON.generate("r" => 1, "g" => 2, "b" => 3))
    assert_equal [ :color, "192.168.10.20", 1, 2, 3 ], @lan.calls[0]
  end

  test "handle_command refresh requests status only" do
    @bridge.handle_command("govee/stehlampe/command/refresh", "{}")
    assert_equal [ [ :request_status, "192.168.10.20" ] ], @lan.calls
  end

  test "handle_command ignores unknown light" do
    @bridge.handle_command("govee/nope/command/turn", JSON.generate("on" => true))
    assert_equal [], @lan.calls
  end

  test "handle_datagram publishes status for the matching ip" do
    payload = JSON.generate("msg" => { "cmd" => "devStatus", "data" => {
      "onOff" => 1, "brightness" => 55, "color" => { "r" => 1, "g" => 2, "b" => 3 },
      "colorTemInKelvin" => 0
    } })
    @bridge.handle_datagram(payload, "192.168.10.20")
    topic, body = @mqtt.published.first
    assert_equal "govee/stehlampe/status", topic
    data = JSON.parse(body)
    assert_equal true, data["on"]
    assert_equal 55,   data["brightness"]
    assert_equal true, data["reachable"]
  end

  test "handle_datagram ignores an unknown ip" do
    payload = JSON.generate("msg" => { "cmd" => "devStatus", "data" => { "onOff" => 1 } })
    @bridge.handle_datagram(payload, "10.0.0.1")
    assert_equal [], @mqtt.published
  end

  test "poll_once requests status for every light" do
    Light.create!(name: "Deckenlampe", key: "deckenlampe", ip_address: "192.168.10.21")
    @bridge.poll_once
    ips = @lan.calls.select { |c| c[0] == :request_status }.map { |c| c[1] }
    assert_includes ips, "192.168.10.20"
    assert_includes ips, "192.168.10.21"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/govee_mqtt_bridge_test.rb`
Expected: FAIL — `cannot load such file -- govee_mqtt_bridge`.

- [ ] **Step 3: Implement the bridge**

```ruby
# lib/govee_mqtt_bridge.rb
require "mqtt"
require "json"
require "socket"
require "govee_lan_client"

# The only component that speaks Govee UDP. Subscribes to govee/+/command/#,
# translates to LAN commands, binds UDP :listen_port for devStatus replies and
# republishes them to govee/<key>/status. Also polls all lights periodically.
class GoveeMqttBridge
  def initialize(mqtt_config:, govee_config:, logger:,
                 lan_client: GoveeLanClient.new,
                 lights_provider: -> { Light.all.to_a },
                 mqtt_factory: nil)
    @mqtt_config     = mqtt_config
    @govee_config    = govee_config
    @logger          = logger
    @lan             = lan_client
    @lights_provider = lights_provider
    @lights          = @lights_provider.call
    @stopping        = false
    @mqtt_factory    = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
    @publisher = nil
  end

  def handle_command(topic, payload)
    cmd   = topic.split("/").last
    key   = topic.split("/")[1]
    @lights = @lights_provider.call if cmd == "refresh"
    light = find_by_key(key)
    return @logger.warn("GoveeMqttBridge: unknown light '#{key}'") unless light

    data = JSON.parse(payload)
    case cmd
    when "turn"       then @lan.turn(light.ip_address, data["on"])
    when "brightness" then @lan.brightness(light.ip_address, data["value"])
    when "color"      then @lan.color(light.ip_address, r: data["r"], g: data["g"], b: data["b"])
    when "color_temp" then @lan.color_temp(light.ip_address, data["temp_k"])
    when "refresh"    then nil # status request below is enough
    else return @logger.warn("GoveeMqttBridge: unknown command '#{cmd}'")
    end
    @lan.request_status(light.ip_address)
  rescue JSON::ParserError => e
    @logger.warn("GoveeMqttBridge: invalid command JSON on #{topic}: #{e.message}")
  end

  def handle_datagram(payload, sender_ip)
    status = GoveeLanClient.parse_status(payload)
    return unless status
    light = find_by_ip(sender_ip)
    return unless light

    body = {
      on:           status.on,
      brightness:   status.brightness,
      color_r:      status.color_r,
      color_g:      status.color_g,
      color_b:      status.color_b,
      color_temp_k: status.color_temp_k,
      reachable:    true,
      sku:          status.sku,
    }
    publisher.publish("#{@govee_config.topic_prefix}/#{light.key}/status", JSON.generate(body))
  end

  def poll_once
    @lights = @lights_provider.call
    @lights.each { |l| @lan.request_status(l.ip_address) }
  end

  def run
    @publisher = @mqtt_factory.call
    @publisher.connect
    threads = [ command_thread, listener_thread, poller_thread ]
    threads.each(&:join)
  ensure
    begin; @publisher&.disconnect; rescue StandardError; nil; end
  end

  def stop!
    @stopping = true
  end

  private

  def find_by_key(key) = @lights.find { |l| l.key == key }
  def find_by_ip(ip)   = @lights.find { |l| l.ip_address == ip }

  def publisher
    @publisher ||= begin
      c = @mqtt_factory.call
      c.connect
      c
    end
  end

  def command_thread
    Thread.new do
      Thread.current.name = "govee_command"
      consumer = @mqtt_factory.call
      consumer.connect
      consumer.subscribe("#{@govee_config.topic_prefix}/+/command/#")
      consumer.get { |t, p| handle_command(t, p) }
    rescue => e
      @logger.error("GoveeMqttBridge command: #{e.class}: #{e.message}")
    end
  end

  def listener_thread
    Thread.new do
      Thread.current.name = "govee_listener"
      socket = UDPSocket.new
      socket.bind("0.0.0.0", @govee_config.listen_port)
      until @stopping
        payload, addr = socket.recvfrom(2048)
        handle_datagram(payload, addr[3])
      end
    rescue => e
      @logger.error("GoveeMqttBridge listener: #{e.class}: #{e.message}")
    end
  end

  def poller_thread
    Thread.new do
      Thread.current.name = "govee_poller"
      until @stopping
        poll_once
        sleep_interruptible(@govee_config.poll_interval_seconds)
      end
    rescue => e
      @logger.error("GoveeMqttBridge poller: #{e.class}: #{e.message}")
    end
  end

  def sleep_interruptible(seconds)
    deadline = Time.now + seconds
    while Time.now < deadline && !@stopping
      sleep([ deadline - Time.now, 1 ].min)
    end
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/govee_mqtt_bridge_test.rb`
Expected: PASS (8 runs, 0 failures).

- [ ] **Step 5: Create the runner binary and commit**

```ruby
# bin/govee_bridge
#!/usr/bin/env ruby
# frozen_string_literal: true

$stdout.sync = true

require_relative "../config/environment"
require "govee_mqtt_bridge"
require "config_loader"

logger = Logger.new($stdout)
logger.level = Rails.env.development? ? Logger::DEBUG : Logger::INFO

config = ConfigLoader.app_config
if config.govee.nil?
  logger.info("govee_bridge: no govee config — nothing to do")
  exit 0
end

bridge = GoveeMqttBridge.new(
  mqtt_config:  config.mqtt,
  govee_config: config.govee,
  logger:       logger,
)

%w[INT TERM].each { |sig| Signal.trap(sig) { bridge.stop! } }

logger.info("govee_bridge: starting")
bridge.run
logger.info("govee_bridge: stopped")
```

```bash
chmod +x bin/govee_bridge
git add lib/govee_mqtt_bridge.rb bin/govee_bridge test/govee_mqtt_bridge_test.rb
git commit -m "Add GoveeMqttBridge and bin/govee_bridge"
```

---

## Task 12: Wire the collector to the router

**Files:**
- Modify: `bin/ziwoas_collector`

**Interfaces:**
- Consumes: `MqttRouter`, `ShellyStatusHandler`, `GoveeStatusHandler` (Tasks 9–10).
- Produces: collector runs one `MqttRouter` thread (Shelly + Govee handlers) plus the existing Fritz bridge threads. No `MqttSubscriber` reference remains.

- [ ] **Step 1: Rewrite the subscriber wiring**

In `bin/ziwoas_collector`, replace the `require "mqtt_subscriber"` line with:

```ruby
require "mqtt_router"
require "shelly_status_handler"
require "govee_status_handler"
```

Replace the `subscriber = MqttSubscriber.new(...)` block and its thread with:

```ruby
handlers = [ ShellyStatusHandler.new(mqtt_config: config.mqtt, plugs: config.plugs, logger: logger) ]
handlers << GoveeStatusHandler.new(topic_prefix: config.govee.topic_prefix, logger: logger) if config.govee

router = MqttRouter.new(mqtt_config: config.mqtt, handlers: handlers, logger: logger)
stoppables << router
threads << Thread.new {
  Thread.current.name = "mqtt_router"
  router.run
}
```

- [ ] **Step 2: Verify the collector boots (syntax + wiring)**

Run: `ruby -c bin/ziwoas_collector`
Expected: `Syntax OK`.

Run: `grep -rn "MqttSubscriber\|mqtt_subscriber" app lib bin test`
Expected: no matches.

- [ ] **Step 3: Run the full suite**

Run: `bin/rails test`
Expected: PASS (no MqttSubscriber references anywhere).

- [ ] **Step 4: Lint**

Run: `bin/rubocop bin/ziwoas_collector lib/mqtt_router.rb lib/shelly_status_handler.rb lib/govee_status_handler.rb`
Expected: no offenses (fix any reported).

- [ ] **Step 5: Commit**

```bash
git add bin/ziwoas_collector
git commit -m "Run Shelly + Govee status through one MqttRouter in the collector"
```

---

## Task 13: RoomsController CRUD

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/rooms_controller.rb`
- Create: `app/views/rooms/index.html.erb`, `app/views/rooms/new.html.erb`, `app/views/rooms/edit.html.erb`, `app/views/rooms/_form.html.erb`
- Test: `test/controllers/rooms_controller_test.rb`

**Interfaces:**
- Produces: standard RESTful `RoomsController` (`index`, `new`, `create`, `edit`, `update`, `destroy`); routes `resources :rooms, except: [:show]`. Strong params: `room: { name }`.

- [ ] **Step 1: Add the route**

In `config/routes.rb`, after the `get "/switches"...` line:

```ruby
  resources :rooms, except: [ :show ]
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/controllers/rooms_controller_test.rb
require "test_helper"

class RoomsControllerTest < ActionDispatch::IntegrationTest
  setup { Room.delete_all }

  test "index lists rooms" do
    Room.create!(name: "Wohnzimmer")
    get rooms_url
    assert_response :success
    assert_match "Wohnzimmer", @response.body
  end

  test "create adds a room and redirects" do
    assert_difference -> { Room.count }, 1 do
      post rooms_url, params: { room: { name: "Küche" } }
    end
    assert_redirected_to rooms_url
  end

  test "create rejects a blank name" do
    assert_no_difference -> { Room.count } do
      post rooms_url, params: { room: { name: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "update renames a room" do
    room = Room.create!(name: "Alt")
    patch room_url(room), params: { room: { name: "Neu" } }
    assert_equal "Neu", room.reload.name
  end

  test "destroy removes a room" do
    room = Room.create!(name: "Weg")
    assert_difference -> { Room.count }, -1 do
      delete room_url(room)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/controllers/rooms_controller_test.rb`
Expected: FAIL — `uninitialized constant RoomsController`.

- [ ] **Step 4: Implement the controller and views**

```ruby
# app/controllers/rooms_controller.rb
class RoomsController < ApplicationController
  before_action :set_room, only: %i[edit update destroy]

  def index = (@rooms = Room.order(:name))
  def new   = (@room = Room.new)
  def edit; end

  def create
    @room = Room.new(room_params)
    if @room.save
      redirect_to rooms_url, notice: "Raum angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @room.update(room_params)
      redirect_to rooms_url, notice: "Raum aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @room.destroy
    redirect_to rooms_url, notice: "Raum gelöscht."
  end

  private

  def set_room    = (@room = Room.find(params[:id]))
  def room_params = params.require(:room).permit(:name)
end
```

```erb
<%# app/views/rooms/index.html.erb %>
<% content_for :title, "Räume" %>
<h1>Räume</h1>
<%= link_to "Neuer Raum", new_room_path %>
<ul>
  <% @rooms.each do |room| %>
    <li>
      <%= room.name %>
      <%= link_to "Bearbeiten", edit_room_path(room) %>
      <%= button_to "Löschen", room_path(room), method: :delete,
                    form: { data: { turbo_confirm: "Raum wirklich löschen?" } } %>
    </li>
  <% end %>
</ul>
```

```erb
<%# app/views/rooms/_form.html.erb %>
<%= form_with model: room do |f| %>
  <% if room.errors.any? %>
    <ul class="form-errors">
      <% room.errors.full_messages.each do |m| %><li><%= m %></li><% end %>
    </ul>
  <% end %>
  <%= f.label :name, "Name" %>
  <%= f.text_field :name %>
  <%= f.submit "Speichern" %>
<% end %>
```

```erb
<%# app/views/rooms/new.html.erb %>
<% content_for :title, "Neuer Raum" %>
<h1>Neuer Raum</h1>
<%= render "form", room: @room %>
```

```erb
<%# app/views/rooms/edit.html.erb %>
<% content_for :title, "Raum bearbeiten" %>
<h1>Raum bearbeiten</h1>
<%= render "form", room: @room %>
```

- [ ] **Step 5: Run the test, lint, commit**

Run: `bin/rails test test/controllers/rooms_controller_test.rb`
Expected: PASS (5 runs, 0 failures).

Run: `bin/rubocop app/controllers/rooms_controller.rb`
Expected: no offenses.

```bash
git add config/routes.rb app/controllers/rooms_controller.rb app/views/rooms test/controllers/rooms_controller_test.rb
git commit -m "Add RoomsController CRUD"
```

---

## Task 14: LightsController CRUD + Verbindung testen

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/lights_controller.rb`
- Create: `app/views/lights/index.html.erb`, `new.html.erb`, `edit.html.erb`, `_form.html.erb`
- Test: `test/controllers/lights_controller_test.rb`

**Interfaces:**
- Consumes: `Light` (Task 2), `Room` (Task 1), `GoveeCommander.refresh` (Task 8), `app_config.mqtt` + `app_config.govee`.
- Produces: RESTful `LightsController` with `param: :key`; routes `resources :lights, param: :key, except: [:show]` plus member `post :test_connection`. `test_connection` calls `GoveeCommander.refresh(...)` and redirects with a notice. Strong params: `light: { name, room_id, ip_address, shelly_plug_id, supports_color, supports_color_temp }` (key is auto-generated, never submitted).

- [ ] **Step 1: Add routes**

```ruby
  resources :lights, param: :key, except: [ :show ] do
    post :test_connection, on: :member
  end
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/controllers/lights_controller_test.rb
require "test_helper"

class LightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    Room.delete_all
  end

  test "index lists lights" do
    Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")
    get lights_url
    assert_response :success
    assert_match "Stehlampe", @response.body
  end

  test "create adds a light, generates a key, redirects" do
    room = Room.create!(name: "Wohnzimmer")
    assert_difference -> { Light.count }, 1 do
      post lights_url, params: { light: { name: "Neue Lampe", room_id: room.id, ip_address: "192.168.10.30" } }
    end
    assert_redirected_to lights_url
    assert_equal "neue_lampe", Light.last.key
  end

  test "create rejects a blank ip" do
    assert_no_difference -> { Light.count } do
      post lights_url, params: { light: { name: "X", ip_address: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "update edits a light by key" do
    light = Light.create!(name: "Lampe", ip_address: "192.168.10.31")
    patch light_url(light), params: { light: { ip_address: "192.168.10.99" } }
    assert_equal "192.168.10.99", light.reload.ip_address
  end

  test "destroy removes a light" do
    light = Light.create!(name: "Weg", ip_address: "192.168.10.32")
    assert_difference -> { Light.count }, -1 do
      delete light_url(light)
    end
  end

  test "test_connection publishes a refresh command and redirects" do
    light = Light.create!(name: "Lampe", ip_address: "192.168.10.33")
    calls = []
    GoveeCommander.stub :refresh, ->(l, **) { calls << l.key } do
      post test_connection_light_url(light)
    end
    assert_equal [ "lampe" ], calls
    assert_redirected_to lights_url
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/controllers/lights_controller_test.rb`
Expected: FAIL — `uninitialized constant LightsController`.

- [ ] **Step 4: Implement the controller and views**

```ruby
# app/controllers/lights_controller.rb
require "govee_commander"

class LightsController < ApplicationController
  before_action :set_light, only: %i[edit update destroy test_connection]

  def index = (@lights = Light.includes(:room).order(:name))
  def new   = (@light = Light.new)
  def edit; end

  def create
    @light = Light.new(light_params)
    if @light.save
      redirect_to lights_url, notice: "Lampe angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

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

  def test_connection
    GoveeCommander.refresh(@light, mqtt_config: app_config.mqtt, topic_prefix: govee_prefix)
    redirect_to lights_url, notice: "Statusabfrage gesendet — Zustand erscheint gleich."
  rescue GoveeCommander::Error
    redirect_to lights_url, alert: "Bridge nicht erreichbar."
  end

  private

  def set_light = (@light = Light.find_by!(key: params[:key]))

  def light_params
    params.require(:light).permit(:name, :room_id, :ip_address, :shelly_plug_id,
                                  :supports_color, :supports_color_temp)
  end

  def govee_prefix = (app_config.govee&.topic_prefix || "govee")
end
```

```erb
<%# app/views/lights/index.html.erb %>
<% content_for :title, "Lampen" %>
<h1>Lampen</h1>
<%= link_to "Neue Lampe", new_light_path %>
<%= link_to "Räume", rooms_path %>
<ul>
  <% @lights.each do |light| %>
    <li>
      <%= light.name %><%= " · #{light.room.name}" if light.room %> — <%= light.ip_address %>
      <%= link_to "Bearbeiten", edit_light_path(light) %>
      <%= button_to "Verbindung testen", test_connection_light_path(light) %>
      <%= button_to "Löschen", light_path(light), method: :delete,
                    form: { data: { turbo_confirm: "Lampe wirklich löschen?" } } %>
    </li>
  <% end %>
</ul>
```

```erb
<%# app/views/lights/_form.html.erb %>
<%= form_with model: light do |f| %>
  <% if light.errors.any? %>
    <ul class="form-errors">
      <% light.errors.full_messages.each do |m| %><li><%= m %></li><% end %>
    </ul>
  <% end %>
  <%= f.label :name, "Name" %>
  <%= f.text_field :name %>

  <%= f.label :room_id, "Raum" %>
  <%= f.collection_select :room_id, Room.order(:name), :id, :name, include_blank: "— kein Raum —" %>

  <%= f.label :ip_address, "IP-Adresse" %>
  <%= f.text_field :ip_address %>

  <%= f.label :shelly_plug_id, "Shelly-Plug (optional)" %>
  <%= f.text_field :shelly_plug_id %>

  <%= f.label :supports_color, "Farbe" %>
  <%= f.check_box :supports_color %>

  <%= f.label :supports_color_temp, "Farbtemperatur" %>
  <%= f.check_box :supports_color_temp %>

  <%= f.submit "Speichern" %>
<% end %>
```

```erb
<%# app/views/lights/new.html.erb %>
<% content_for :title, "Neue Lampe" %>
<h1>Neue Lampe</h1>
<%= render "form", light: @light %>
```

```erb
<%# app/views/lights/edit.html.erb %>
<% content_for :title, "Lampe bearbeiten" %>
<h1>Lampe bearbeiten</h1>
<%= render "form", light: @light %>
```

- [ ] **Step 5: Run the test, lint, commit**

Run: `bin/rails test test/controllers/lights_controller_test.rb`
Expected: PASS (6 runs, 0 failures).

Run: `bin/rubocop app/controllers/lights_controller.rb`
Expected: no offenses.

```bash
git add config/routes.rb app/controllers/lights_controller.rb app/views/lights test/controllers/lights_controller_test.rb
git commit -m "Add LightsController CRUD with test-connection"
```

---

## Task 15: LightSwitchesController (commands)

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/light_switches_controller.rb`
- Test: `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Consumes: `Light` (Task 2), `GoveeCommander` (Task 8).
- Produces: `POST /lights/:light_key/command` → `LightSwitchesController#create`, route name `light_command`. Accepts `command` ∈ {`turn`,`brightness`,`color`,`color_temp`} plus its params. Responds `202 Accepted` on success (optimistic; the UI updates via broadcast). `404` unknown light, `422` invalid command, `503` on `GoveeCommander::Error`.

- [ ] **Step 1: Add the route**

```ruby
  scope "/lights/:light_key" do
    post "command", to: "light_switches#create", as: :light_command
  end
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/controllers/light_switches_controller_test.rb
require "test_helper"

class LightSwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    @light = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")
    @calls = []
  end

  test "unknown light returns 404" do
    post light_command_url(light_key: "nope"), params: { command: "turn", on: "true" }
    assert_response :not_found
  end

  test "invalid command returns 422" do
    post light_command_url(light_key: @light.key), params: { command: "explode" }
    assert_response :unprocessable_entity
  end

  test "turn calls GoveeCommander and responds 202" do
    GoveeCommander.stub :turn, ->(l, **kw) { @calls << [ l.key, kw[:on] ] } do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :accepted
    assert_equal [ [ "stehlampe", true ] ], @calls
  end

  test "brightness forwards the integer value" do
    GoveeCommander.stub :set_brightness, ->(l, **kw) { @calls << kw[:value] } do
      post light_command_url(light_key: @light.key), params: { command: "brightness", value: "42" }
    end
    assert_response :accepted
    assert_equal [ 42 ], @calls
  end

  test "broker failure responds 503" do
    failing = ->(*, **) { raise GoveeCommander::Error, "broker down" }
    GoveeCommander.stub :turn, failing do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :service_unavailable
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: FAIL — `uninitialized constant LightSwitchesController`.

- [ ] **Step 4: Implement the controller**

```ruby
# app/controllers/light_switches_controller.rb
require "govee_commander"

class LightSwitchesController < ApplicationController
  def create
    light = Light.find_by(key: params[:light_key])
    return head :not_found unless light

    case params[:command]
    when "turn"
      GoveeCommander.turn(light, on: cast_bool(params[:on]), source: :manual, **opts)
    when "brightness"
      GoveeCommander.set_brightness(light, value: params[:value].to_i, source: :manual, **opts)
    when "color"
      GoveeCommander.set_color(light, r: params[:r].to_i, g: params[:g].to_i, b: params[:b].to_i,
                               source: :manual, **opts)
    when "color_temp"
      GoveeCommander.set_color_temp(light, kelvin: params[:temp_k].to_i, source: :manual, **opts)
    else
      return head :unprocessable_entity
    end

    head :accepted
  rescue GoveeCommander::Error
    head :service_unavailable
  end

  private

  def opts = { mqtt_config: app_config.mqtt, topic_prefix: app_config.govee&.topic_prefix || "govee" }
  def cast_bool(v) = ActiveModel::Type::Boolean.new.cast(v)
end
```

- [ ] **Step 5: Run the test, lint, commit**

Run: `bin/rails test test/controllers/light_switches_controller_test.rb`
Expected: PASS (5 runs, 0 failures).

Run: `bin/rubocop app/controllers/light_switches_controller.rb`
Expected: no offenses.

```bash
git add config/routes.rb app/controllers/light_switches_controller.rb test/controllers/light_switches_controller_test.rb
git commit -m "Add LightSwitchesController for Govee commands"
```

---

## Task 16: Lights section on the switches page

**Files:**
- Create: `app/models/light_row.rb`
- Create: `app/views/switches/_light_card.html.erb`
- Create: `app/views/switches/_light_head.html.erb`
- Modify: `app/controllers/switches_controller.rb`
- Modify: `app/views/switches/index.html.erb`
- Test: `test/models/light_row_test.rb`

**Interfaces:**
- Consumes: `Light`, `LightState`.
- Produces: `LightRow` view model — `LightRow.build_all(lights) -> Array<LightRow>`; instance readers `light`, `state`; helpers `on? -> Boolean` (from `state&.on`), `brightness -> Integer` (from `state&.brightness || 0`), `reachable? -> Boolean` (from `state&.reachable`). `SwitchesController#index` assigns `@light_rows = LightRow.build_all(Light.order(:name))`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/light_row_test.rb
require "test_helper"

class LightRowTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    LightState.delete_all
  end

  test "build_all returns a row per light with its state" do
    light = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")
    LightState.record_state(light.key, on: true, brightness: 70, reachable: true)

    rows = LightRow.build_all(Light.order(:name))
    assert_equal 1, rows.length
    row = rows.first
    assert_equal light, row.light
    assert_equal true,  row.on?
    assert_equal 70,    row.brightness
    assert_equal true,  row.reachable?
  end

  test "defaults are safe when no state exists" do
    Light.create!(name: "Neu", ip_address: "192.168.10.21")
    row = LightRow.build_all(Light.all).first
    assert_equal false, row.on?
    assert_equal 0,     row.brightness
    assert_equal false, row.reachable?
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/light_row_test.rb`
Expected: FAIL — `uninitialized constant LightRow`.

- [ ] **Step 3: Implement the view model, controller, views**

```ruby
# app/models/light_row.rb
# Per-light view model for the "Schalten" tab.
class LightRow
  attr_reader :light, :state

  def self.build_all(lights)
    lights  = lights.to_a
    states  = LightState.where(light_key: lights.map(&:key)).index_by(&:light_key)
    lights.map { |l| new(light: l, state: states[l.key]) }
  end

  def initialize(light:, state:)
    @light = light
    @state = state
  end

  def on?         = !!state&.on
  def brightness  = state&.brightness || 0
  def reachable?  = !!state&.reachable
end
```

In `app/controllers/switches_controller.rb`, add to `#index`:

```ruby
    @light_rows = LightRow.build_all(Light.order(:name))
```

```erb
<%# app/views/switches/_light_head.html.erb %>
<div class="sw-head" id="light_head_<%= row.light.key %>">
  <div class="sw-info">
    <span class="sw-name"><%= row.light.name %></span>
    <div class="sw-error" id="light_error_<%= row.light.key %>"></div>
  </div>
  <div class="sw-knob-col">
    <button class="sw-knob<%= ' off' unless row.on? %>"
            data-action="lights#toggle" data-lights-key-param="<%= row.light.key %>"
            aria-label="<%= row.light.name %> umschalten"></button>
  </div>
</div>
```

```erb
<%# app/views/switches/_light_card.html.erb %>
<div class="sw-card sw-light-card" id="light_card_<%= row.light.key %>"
     data-light-key="<%= row.light.key %>">
  <%= render "switches/light_head", row: row %>
  <input type="range" min="0" max="100" value="<%= row.brightness %>"
         data-action="lights#brightness" data-lights-key-param="<%= row.light.key %>"
         data-lights-target="brightness" aria-label="Helligkeit <%= row.light.name %>">
  <% if row.light.supports_color %>
    <input type="color" data-action="lights#color"
           data-lights-key-param="<%= row.light.key %>" aria-label="Farbe <%= row.light.name %>">
  <% end %>
</div>
```

In `app/views/switches/index.html.erb`, inside the `data-controller="switches"` wrapper, after the plug cards loop, add a lights section under its own Stimulus controller:

```erb
  <% if @light_rows.any? %>
    <h2 class="section-label">Lampen</h2>
    <div data-controller="lights">
      <% @light_rows.each do |row| %>
        <%= render "switches/light_card", row: row %>
      <% end %>
    </div>
  <% end %>
```

- [ ] **Step 4: Run the test and the switches controller test**

Run: `bin/rails test test/models/light_row_test.rb test/controllers/switches_controller_test.rb`
Expected: PASS (existing switches controller test still green; new LightRow test green). If there is no `test/controllers/switches_controller_test.rb`, run only the LightRow test.

- [ ] **Step 5: Lint and commit**

Run: `bin/rubocop app/models/light_row.rb app/controllers/switches_controller.rb`
Expected: no offenses.

```bash
git add app/models/light_row.rb app/views/switches app/controllers/switches_controller.rb test/models/light_row_test.rb
git commit -m "Show lights section on the switches page"
```

---

## Task 17: lights_controller.js Stimulus controller

**Files:**
- Create: `app/javascript/controllers/lights_controller.js`
- Test: `test/system/lights_test.rb` (smoke; optional run depending on system-test setup)

**Interfaces:**
- Consumes: `light_command` route (Task 15), `DashboardChannel` ActionCable broadcasts carrying `{ lights: [...] }` (Task 10).
- Produces: a Stimulus controller `lights` that (a) posts commands (`toggle`, `brightness` debounced, `color` debounced) to `/lights/:key/command`, sets the card to a `pending` class immediately, and (b) on a matching broadcast clears `pending` and applies the confirmed state; a JS timeout marks the card `unconfirmed` if no broadcast arrives.

- [ ] **Step 1: Write the controller**

```javascript
// app/javascript/controllers/lights_controller.js
import { Controller } from "@hotwired/stimulus"
import consumer from "channels/consumer"

// Connects to data-controller="lights". Sends Govee commands optimistically
// (card shows .pending) and reconciles to the confirmed state from the
// "dashboard" ActionCable broadcasts ({ lights: [...] }) produced by
// GoveeStatusHandler.
export default class extends Controller {
  connect() {
    this.timeouts = {}
    this.debounces = {}
    this.subscription = consumer.subscriptions.create("DashboardChannel", {
      received: (data) => this.handleBroadcast(data),
    })
  }

  disconnect() {
    this.subscription?.unsubscribe()
  }

  toggle(event) {
    const key = event.params.key
    const card = this.cardFor(key)
    const on = !card.querySelector("button.sw-knob").classList.contains("off")
    this.send(key, { command: "turn", on: (!on).toString() })
  }

  brightness(event) {
    const key = event.params.key
    const value = event.target.value
    this.debounced(key, () => this.send(key, { command: "brightness", value }))
  }

  color(event) {
    const key = event.params.key
    const hex = event.target.value // #rrggbb
    const r = parseInt(hex.slice(1, 3), 16)
    const g = parseInt(hex.slice(3, 5), 16)
    const b = parseInt(hex.slice(5, 7), 16)
    this.debounced(key, () => this.send(key, { command: "color", r, g, b }))
  }

  debounced(key, fn) {
    clearTimeout(this.debounces[key])
    this.debounces[key] = setTimeout(fn, 250)
  }

  send(key, body) {
    const card = this.cardFor(key)
    if (card) card.classList.add("pending")
    const params = new URLSearchParams(body)
    fetch(`/lights/${key}/command`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      },
      body: params.toString(),
    })
    clearTimeout(this.timeouts[key])
    this.timeouts[key] = setTimeout(() => this.markUnconfirmed(key), 5000)
  }

  handleBroadcast(data) {
    if (!Array.isArray(data.lights)) return
    data.lights.forEach((light) => this.applyState(light))
  }

  applyState(light) {
    const card = this.cardFor(light.light_key)
    if (!card) return
    clearTimeout(this.timeouts[light.light_key])
    card.classList.remove("pending", "unconfirmed")

    if (typeof light.on === "boolean") {
      const knob = card.querySelector("button.sw-knob")
      if (knob) knob.classList.toggle("off", !light.on)
    }
    if (typeof light.brightness === "number") {
      const slider = card.querySelector('input[type="range"]')
      if (slider) slider.value = light.brightness
    }
    const error = card.querySelector(".sw-error")
    if (error) error.textContent = ""
  }

  markUnconfirmed(key) {
    const card = this.cardFor(key)
    if (!card) return
    card.classList.remove("pending")
    card.classList.add("unconfirmed")
    const error = card.querySelector(".sw-error")
    if (error) error.textContent = "Nicht bestätigt"
  }

  cardFor(key) {
    return this.element.querySelector(`[data-light-key="${key}"]`)
  }
}
```

- [ ] **Step 2: Verify the controller registers (asset build)**

Run: `bin/rails test test/controllers/switches_controller_test.rb` (or `bin/rails runner "puts 'ok'"` if no switches controller test exists)
Expected: no errors; Stimulus auto-registers controllers via the importmap/`stimulus-loading` (no manual registration needed — confirm the project uses `eagerLoadControllersFrom`). If controllers are manually registered in `app/javascript/controllers/index.js`, add the registration line there:

```javascript
import LightsController from "controllers/lights_controller"
application.register("lights", LightsController)
```

(Check `app/javascript/controllers/index.js` first; only add if registrations are manual.)

- [ ] **Step 3: Manual smoke check**

Run: `bin/dev` (or `bin/rails server`), open `/switches`, confirm a lamp card renders with a knob and a brightness slider and clicking the knob issues a POST (visible in the server log as `LightSwitchesController#create ... 202`).
Expected: 202 response; card gets `.pending` then resolves (or `.unconfirmed` after 5s if the bridge is not running).

- [ ] **Step 4: Lint (if eslint configured) — otherwise skip**

Run: `npx eslint app/javascript/controllers/lights_controller.js 2>/dev/null || echo "no eslint configured — skipping"`
Expected: no errors or a skip message.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/lights_controller.js app/javascript/controllers/index.js
git commit -m "Add lights Stimulus controller with optimistic pending state"
```

---

## Task 18: PresetsController + ScenesController (CRUD + apply)

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/presets_controller.rb`, `app/controllers/scenes_controller.rb`
- Create: views under `app/views/presets/` and `app/views/scenes/`
- Test: `test/controllers/presets_controller_test.rb`, `test/controllers/scenes_controller_test.rb`

**Interfaces:**
- Consumes: `Preset`, `Scene`, `SceneEntry`, `Light` (Task 4), `GoveeCommander` (Task 8).
- Produces: RESTful `PresetsController` (`index/new/create/edit/update/destroy`); RESTful `ScenesController` with an extra member `POST /scenes/:id/apply` (`scenes#apply`) that, for each `SceneEntry`, calls `GoveeCommander.turn` and (when on) `set_brightness` and the appropriate color command. Routes: `resources :presets, except: [:show]`; `resources :scenes, except: [:show] do post :apply, on: :member end`.

- [ ] **Step 1: Add routes**

```ruby
  resources :presets, except: [ :show ]
  resources :scenes, except: [ :show ] do
    post :apply, on: :member
  end
```

- [ ] **Step 2: Write the failing tests**

```ruby
# test/controllers/presets_controller_test.rb
require "test_helper"

class PresetsControllerTest < ActionDispatch::IntegrationTest
  setup { Preset.delete_all }

  test "index lists presets" do
    Preset.create!(name: "Warm 20%", brightness: 20, color_temp_k: 2700)
    get presets_url
    assert_response :success
    assert_match "Warm 20%", @response.body
  end

  test "create adds a preset" do
    assert_difference -> { Preset.count }, 1 do
      post presets_url, params: { preset: { name: "Hell", brightness: 100, on: true } }
    end
    assert_redirected_to presets_url
  end

  test "destroy removes a preset" do
    preset = Preset.create!(name: "Weg")
    assert_difference -> { Preset.count }, -1 do
      delete preset_url(preset)
    end
  end
end
```

```ruby
# test/controllers/scenes_controller_test.rb
require "test_helper"

class ScenesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Scene.delete_all
    Light.delete_all
    Preset.delete_all
  end

  test "create adds a scene" do
    assert_difference -> { Scene.count }, 1 do
      post scenes_url, params: { scene: { name: "Kino" } }
    end
    assert_redirected_to scenes_url
  end

  test "apply issues a turn command per entry and responds" do
    scene  = Scene.create!(name: "Kino")
    light  = Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")
    preset = Preset.create!(name: "Warm 20%", on: true, brightness: 20, color_temp_k: 2700)
    scene.scene_entries.create!(light: light, preset: preset)

    turns = []
    GoveeCommander.stub :turn, ->(l, **kw) { turns << [ l.key, kw[:on] ] } do
      GoveeCommander.stub :set_brightness, ->(*, **) {} do
        GoveeCommander.stub :set_color_temp, ->(*, **) {} do
          post apply_scene_url(scene)
        end
      end
    end
    assert_redirected_to scenes_url
    assert_equal [ [ "stehlampe", true ] ], turns
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bin/rails test test/controllers/presets_controller_test.rb test/controllers/scenes_controller_test.rb`
Expected: FAIL — `uninitialized constant PresetsController` / `ScenesController`.

- [ ] **Step 4: Implement controllers and views**

```ruby
# app/controllers/presets_controller.rb
class PresetsController < ApplicationController
  before_action :set_preset, only: %i[edit update destroy]

  def index = (@presets = Preset.order(:name))
  def new   = (@preset = Preset.new)
  def edit; end

  def create
    @preset = Preset.new(preset_params)
    if @preset.save
      redirect_to presets_url, notice: "Preset angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @preset.update(preset_params)
      redirect_to presets_url, notice: "Preset aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @preset.destroy
    redirect_to presets_url, notice: "Preset gelöscht."
  end

  private

  def set_preset = (@preset = Preset.find(params[:id]))

  def preset_params
    params.require(:preset).permit(:name, :on, :brightness, :color_r, :color_g, :color_b, :color_temp_k)
  end
end
```

```ruby
# app/controllers/scenes_controller.rb
require "govee_commander"

class ScenesController < ApplicationController
  before_action :set_scene, only: %i[edit update destroy apply]

  def index = (@scenes = Scene.includes(scene_entries: %i[light preset]).order(:name))
  def new   = (@scene = Scene.new)
  def edit; end

  def create
    @scene = Scene.new(scene_params)
    if @scene.save
      redirect_to scenes_url, notice: "Szene angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @scene.update(scene_params)
      redirect_to scenes_url, notice: "Szene aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @scene.destroy
    redirect_to scenes_url, notice: "Szene gelöscht."
  end

  def apply
    @scene.scene_entries.each { |entry| apply_entry(entry) }
    redirect_to scenes_url, notice: "Szene angewendet."
  rescue GoveeCommander::Error
    redirect_to scenes_url, alert: "Bridge nicht erreichbar."
  end

  private

  def set_scene    = (@scene = Scene.find(params[:id]))
  def scene_params = params.require(:scene).permit(:name)

  def apply_entry(entry)
    light, preset = entry.light, entry.preset
    GoveeCommander.turn(light, on: preset.on, source: :scene, **opts)
    return unless preset.on
    GoveeCommander.set_brightness(light, value: preset.brightness, source: :scene, **opts) if preset.brightness
    if preset.color_temp_k && preset.color_temp_k > 0
      GoveeCommander.set_color_temp(light, kelvin: preset.color_temp_k, source: :scene, **opts)
    elsif preset.color_r
      GoveeCommander.set_color(light, r: preset.color_r, g: preset.color_g, b: preset.color_b,
                               source: :scene, **opts)
    end
  end

  def opts = { mqtt_config: app_config.mqtt, topic_prefix: app_config.govee&.topic_prefix || "govee" }
end
```

```erb
<%# app/views/presets/index.html.erb %>
<% content_for :title, "Presets" %>
<h1>Presets</h1>
<%= link_to "Neues Preset", new_preset_path %>
<ul>
  <% @presets.each do |preset| %>
    <li>
      <%= preset.name %>
      <%= link_to "Bearbeiten", edit_preset_path(preset) %>
      <%= button_to "Löschen", preset_path(preset), method: :delete,
                    form: { data: { turbo_confirm: "Preset löschen?" } } %>
    </li>
  <% end %>
</ul>
```

```erb
<%# app/views/presets/_form.html.erb %>
<%= form_with model: preset do |f| %>
  <% if preset.errors.any? %>
    <ul class="form-errors">
      <% preset.errors.full_messages.each do |m| %><li><%= m %></li><% end %>
    </ul>
  <% end %>
  <%= f.label :name, "Name" %>            <%= f.text_field :name %>
  <%= f.label :on, "An" %>                <%= f.check_box :on %>
  <%= f.label :brightness, "Helligkeit" %><%= f.number_field :brightness, in: 0..100 %>
  <%= f.label :color_temp_k, "Farbtemperatur (K)" %><%= f.number_field :color_temp_k %>
  <%= f.label :color_r, "R" %><%= f.number_field :color_r, in: 0..255 %>
  <%= f.label :color_g, "G" %><%= f.number_field :color_g, in: 0..255 %>
  <%= f.label :color_b, "B" %><%= f.number_field :color_b, in: 0..255 %>
  <%= f.submit "Speichern" %>
<% end %>
```

```erb
<%# app/views/presets/new.html.erb %>
<% content_for :title, "Neues Preset" %>
<h1>Neues Preset</h1>
<%= render "form", preset: @preset %>
```

```erb
<%# app/views/presets/edit.html.erb %>
<% content_for :title, "Preset bearbeiten" %>
<h1>Preset bearbeiten</h1>
<%= render "form", preset: @preset %>
```

```erb
<%# app/views/scenes/index.html.erb %>
<% content_for :title, "Szenen" %>
<h1>Szenen</h1>
<%= link_to "Neue Szene", new_scene_path %>
<ul>
  <% @scenes.each do |scene| %>
    <li>
      <%= scene.name %> (<%= scene.scene_entries.size %> Lampen)
      <%= button_to "Anwenden", apply_scene_path(scene) %>
      <%= link_to "Bearbeiten", edit_scene_path(scene) %>
      <%= button_to "Löschen", scene_path(scene), method: :delete,
                    form: { data: { turbo_confirm: "Szene löschen?" } } %>
    </li>
  <% end %>
</ul>
```

```erb
<%# app/views/scenes/_form.html.erb %>
<%= form_with model: scene do |f| %>
  <% if scene.errors.any? %>
    <ul class="form-errors">
      <% scene.errors.full_messages.each do |m| %><li><%= m %></li><% end %>
    </ul>
  <% end %>
  <%= f.label :name, "Name" %>
  <%= f.text_field :name %>
  <%= f.submit "Speichern" %>
<% end %>
<p>Lampen-Zuordnung (Lampe → Preset) wird nach dem Anlegen über die Szene-Einträge gepflegt.</p>
```

```erb
<%# app/views/scenes/new.html.erb %>
<% content_for :title, "Neue Szene" %>
<h1>Neue Szene</h1>
<%= render "form", scene: @scene %>
```

```erb
<%# app/views/scenes/edit.html.erb %>
<% content_for :title, "Szene bearbeiten" %>
<h1>Szene bearbeiten</h1>
<%= render "form", scene: @scene %>
```

- [ ] **Step 5: Run the tests, lint, commit**

Run: `bin/rails test test/controllers/presets_controller_test.rb test/controllers/scenes_controller_test.rb`
Expected: PASS.

Run: `bin/rubocop app/controllers/presets_controller.rb app/controllers/scenes_controller.rb`
Expected: no offenses.

```bash
git add config/routes.rb app/controllers/presets_controller.rb app/controllers/scenes_controller.rb app/views/presets app/views/scenes test/controllers/presets_controller_test.rb test/controllers/scenes_controller_test.rb
git commit -m "Add Presets and Scenes CRUD with scene apply"
```

---

## Final Verification

- [ ] **Run the full suite**

Run: `bin/rails test`
Expected: PASS — baseline 518 plus all new tests, 0 failures.

- [ ] **Lint the whole change**

Run: `bin/rubocop`
Expected: no offenses.

- [ ] **Confirm no stale references**

Run: `grep -rn "MqttSubscriber\|mqtt_subscriber" app lib bin test`
Expected: no matches.

- [ ] **Manual end-to-end (optional, needs hardware + bridge)**

1. Add a `govee:` block to `config/ziwoas.yml`.
2. Create a `Room` and a `Light` (fixed IP) via the UI; click "Verbindung testen".
3. Start `bin/govee_bridge` and `bin/ziwoas_collector`.
4. On `/switches`, toggle the lamp and move the brightness slider; confirm the card resolves from `pending` to the confirmed state.
