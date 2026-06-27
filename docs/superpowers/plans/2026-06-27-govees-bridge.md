# govees-Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the external `govee2mqtt` binary with an in-house Ruby bridge `govees` that controls Govee lamps LAN-first (API as fallback/for scenes & zone reconcile), fixes quirks at the source, and serves an optimistic + eventually-consistent state on a clean MQTT contract.

**Architecture:** A set of focused classes under `lib/govees/` runs as supervised threads inside `bin/ziwoas_collector` (like the existing Fritz bridge). The bridge talks to lamps over UDP LAN (`turn`/`brightness`/`colorwc`/`devStatus`/`scan`) and the documented Govee Platform API (API-key only), holds per-lamp desired/confirmed state with conflict resolution, and publishes `govees/<id>/config` + `govees/<id>/state` to the MQTT broker. The existing collector handlers (rewritten, thinner) consume those topics into `Light`/`LightState` exactly as today; the web UI is unchanged. The bridge subscribes `govees/<id>/set` for commands.

**Tech Stack:** Ruby, Rails (models/ActionCable/Turbo), `mqtt` gem, `socket` (UDP), `net/http` (Platform API), Minitest + WebMock, MQTT broker (Mosquitto).

## Global Constraints

- Ruby/Rails project; library code lives in `lib/`, required by bare name (e.g. `require "govees/bridge"`); tests in `test/` use Minitest (`ActiveSupport::TestCase`), run via `bin/rails test`.
- `bin/ci` must stay green: 588+ tests/0 failures, RuboCop, brakeman 0 warnings. **`bin/ci` requires the `bin/dev` stack stopped** (a running collector locks the SQLite DB).
- `Light#key` format is `/\A[0-9A-Za-z]+\z/` (no colons) — the lamp key is the Govee MAC uppercased with colons stripped (e.g. API id `14:AB:DB:48:44:06:4B:60` → key `14ABDB4844064B60`).
- MQTT topic prefix for govee is the literal `govees` (analogous to `shellies`); never `gv2mqtt`.
- Brightness is native percent `0–100`; color temperature is native Kelvin (NO Mired conversion anywhere).
- API key comes from `ENV["GOVEE_API_KEY"]` (already in `config/govee2mqtt.env`, gitignored secret). Platform API base: `https://openapi.api.govee.com`, header `Govee-API-Key`. Status code lives in the JSON body (`{"code":200,...}`), not the HTTP status.
- Out of scope (do NOT implement): segments, per-zone color, AWS-IoT/account login, BLE, active-scene UI reflection, live mirroring faster than the LAN poll.
- All time-dependent classes take an injectable `clock:` (default `-> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }`); all socket/HTTP/MQTT use injectable factories so tests never touch the network. WebMock blocks real HTTP.

---

## File Structure

**New (`lib/govees/`):**
- `lib/govees/lan_client.rb` — UDP LAN protocol: `scan` (multicast discovery), `turn`/`brightness`/`colorwc`/`devStatus` control, response parsing. No DB, no MQTT.
- `lib/govees/platform_api.rb` — HTTP client for `/user/devices`, `/device/state`, `/device/control`, `/device/scenes`; body-code handling, backoff, tiny TTL cache.
- `lib/govees/device.rb` — value object describing one lamp (key, api_id, sku, name, ip, capability flags, zones, scenes + scene index, power_only).
- `lib/govees/device_registry.rb` — builds/merges `Device`s from API (authoritative) + LAN scan (IP), curates zones/scenes.
- `lib/govees/state_store.rb` — per-lamp desired/confirmed/status + the conflict-resolution logic (the heart). Injectable clock.
- `lib/govees/command_router.rb` — turns one `govees/<id>/set` verb into a LAN or API call per capability; records optimistic state.
- `lib/govees/reconciler.rb` — LAN poll tick, API poll tick, on-demand API clarification.
- `lib/govees/bridge.rb` — orchestrator: owns MQTT client (sub `govees/+/set`, pub config/state), starts/stops threads, publishes on state change.

**Rewritten consumer (`lib/`):**
- `lib/govees_discovery_handler.rb` (replaces `govee_discovery_handler.rb` + `govee_zone_discovery_handler.rb`).
- `lib/govees_status_handler.rb` (replaces `govee_status_handler.rb` + `govee_zone_state_handler.rb`).
- `lib/govees_commander.rb` (replaces `govee_commander.rb`).

**Modified:**
- `lib/config_loader.rb` — add `GoveeCfg` + `build_govee`.
- `bin/ziwoas_collector` — wire the bridge + new handlers; drop old handlers.
- `app/controllers/light_switches_controller.rb` — call `GoveesCommander` with `set`-verbs.
- `config/ziwoas.example.yml` — document the `govee:` block.

**Removed (final task):** `config/govee2mqtt.env*`, `vendor/govee2mqtt/`, `Brewfile` rust line, `docs/govee2mqtt-setup.md`, the `govee2mqtt` service in `docker-compose*.yml`, the `govee` entry in `Procfile.dev`, and the four `govee_*` handler files + their tests.

---

## Task 1: `Govees::LanClient` — UDP LAN protocol

**Files:**
- Create: `lib/govees/lan_client.rb`
- Test: `test/govees/lan_client_test.rb`

**Interfaces:**
- Produces:
  - `Govees::LanClient.new(socket_factory: -> { UDPSocket.new })`
  - `#turn(ip, on)`, `#brightness(ip, value)`, `#color(ip, r:, g:, b:)`, `#color_temp(ip, kelvin)`, `#request_status(ip)` — all send one UDP datagram to `ip:4003`.
  - `Govees::LanClient.parse_status(payload) -> Status | nil` where `Status = Struct.new(:on, :brightness, :color_r, :color_g, :color_b, :color_temp_k, :sku, keyword_init: true)`.
  - `Govees::LanClient.scan_request -> String` (the JSON scan datagram body) and `Govees::LanClient.parse_scan(payload) -> {ip:, mac:, sku:} | nil`.
  - Constants: `CMD_PORT=4003`, `SCAN_MCAST="239.255.255.250"`, `SCAN_PORT=4001`, `LISTEN_PORT=4002`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/lan_client_test.rb
require "test_helper"
require "govees/lan_client"

class GoveesLanClientTest < ActiveSupport::TestCase
  # Fake UDP socket records what was sent instead of touching the network.
  class FakeSocket
    attr_reader :sent
    def initialize = @sent = []
    def send(data, _flags, host, port) = @sent << { data: data, host: host, port: port }
    def close = nil
  end

  setup do
    @sock   = FakeSocket.new
    @client = Govees::LanClient.new(socket_factory: -> { @sock })
  end

  test "turn sends a Govee turn datagram to port 4003" do
    @client.turn("192.168.8.184", true)
    msg = @sock.sent.first
    assert_equal "192.168.8.184", msg[:host]
    assert_equal 4003, msg[:port]
    assert_equal({ "cmd" => "turn", "data" => { "value" => 1 } }, JSON.parse(msg[:data])["msg"])
  end

  test "color sends colorwc with rgb and zero kelvin" do
    @client.color("1.2.3.4", r: 10, g: 20, b: 30)
    data = JSON.parse(@sock.sent.first[:data]).dig("msg", "data")
    assert_equal({ "r" => 10, "g" => 20, "b" => 30 }, data["color"])
    assert_equal 0, data["colorTemInKelvin"]
  end

  test "color_temp sends colorwc with kelvin and zero rgb" do
    @client.color_temp("1.2.3.4", 3000)
    data = JSON.parse(@sock.sent.first[:data]).dig("msg", "data")
    assert_equal 3000, data["colorTemInKelvin"]
  end

  test "parse_status maps onOff/brightness/color/kelvin/sku" do
    payload = JSON.generate("msg" => { "data" => {
      "onOff" => 1, "brightness" => 42, "color" => { "r" => 1, "g" => 2, "b" => 3 },
      "colorTemInKelvin" => 3500, "sku" => "H60B0" } })
    s = Govees::LanClient.parse_status(payload)
    assert_equal true, s.on
    assert_equal 42, s.brightness
    assert_equal 3, s.color_b
    assert_equal 3500, s.color_temp_k
    assert_equal "H60B0", s.sku
  end

  test "parse_status returns nil for non-status payloads" do
    assert_nil Govees::LanClient.parse_status(JSON.generate("msg" => { "data" => {} }))
    assert_nil Govees::LanClient.parse_status("not-json{")
  end

  test "parse_scan extracts ip, mac and sku from a scan reply" do
    payload = JSON.generate("msg" => { "cmd" => "scan", "data" => {
      "ip" => "192.168.8.184", "device" => "14:AB:DB:48:44:06:4B:60", "sku" => "H60B0" } })
    assert_equal({ ip: "192.168.8.184", mac: "14:AB:DB:48:44:06:4B:60", sku: "H60B0" },
                 Govees::LanClient.parse_scan(payload))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/lan_client_test.rb`
Expected: FAIL with `cannot load such file -- govees/lan_client`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/lan_client.rb
require "json"
require "socket"

module Govees
  # Pure Govee LAN protocol: serialize commands, send UDP to :4003, parse
  # devStatus + scan replies. No MQTT, no DB. Socket factory is injectable.
  class LanClient
    CMD_PORT   = 4003
    SCAN_MCAST = "239.255.255.250"
    SCAN_PORT  = 4001
    LISTEN_PORT = 4002

    Status = Struct.new(:on, :brightness, :color_r, :color_g, :color_b,
                        :color_temp_k, :sku, keyword_init: true)

    def initialize(socket_factory: -> { UDPSocket.new })
      @socket_factory = socket_factory
    end

    def turn(ip, on)          = send_command(ip, "turn",       { "value" => on ? 1 : 0 })
    def brightness(ip, value) = send_command(ip, "brightness", { "value" => value.to_i })
    def request_status(ip)    = send_command(ip, "devStatus",  {})

    def color(ip, r:, g:, b:)
      send_command(ip, "colorwc",
        { "color" => { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i }, "colorTemInKelvin" => 0 })
    end

    def color_temp(ip, kelvin)
      send_command(ip, "colorwc",
        { "color" => { "r" => 0, "g" => 0, "b" => 0 }, "colorTemInKelvin" => kelvin.to_i })
    end

    def self.scan_request = JSON.generate("msg" => { "cmd" => "scan", "data" => { "account_topic" => "reserve" } })

    def self.parse_status(payload)
      data = JSON.parse(payload).dig("msg", "data")
      return nil unless data.is_a?(Hash) && data.key?("onOff")
      color = data["color"] || {}
      Status.new(on: data["onOff"] == 1, brightness: data["brightness"],
                 color_r: color["r"], color_g: color["g"], color_b: color["b"],
                 color_temp_k: data["colorTemInKelvin"], sku: data["sku"])
    rescue JSON::ParserError
      nil
    end

    def self.parse_scan(payload)
      data = JSON.parse(payload).dig("msg", "data")
      return nil unless data.is_a?(Hash) && data["ip"] && data["device"]
      { ip: data["ip"], mac: data["device"], sku: data["sku"] }
    rescue JSON::ParserError
      nil
    end

    private

    def send_command(ip, cmd, data)
      socket = @socket_factory.call
      socket.send(JSON.generate("msg" => { "cmd" => cmd, "data" => data }), 0, ip, CMD_PORT)
    ensure
      begin; socket&.close; rescue StandardError; nil; end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees/lan_client_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/lan_client.rb test/govees/lan_client_test.rb
git commit -m "feat(govees): LAN UDP client (control + devStatus/scan parsing)"
```

---

## Task 2: `Govees::PlatformApi` — documented Cloud API client

**Files:**
- Create: `lib/govees/platform_api.rb`
- Test: `test/govees/platform_api_test.rb`

**Interfaces:**
- Consumes: `ENV["GOVEE_API_KEY"]` (passed in as `api_key:`).
- Produces:
  - `Govees::PlatformApi.new(api_key:, http: Net::HTTP, clock: ...)`
  - `#devices -> Array<Hash>` (raw `data` array from `/user/devices`).
  - `#state(sku:, device:) -> Hash` mapping instance name → value (e.g. `{"powerSwitch"=>1,"brightness"=>100,"colorTemperatureK"=>2702,"online"=>true,"rippleLightToggle"=>1,"colorRgb"=>0}`).
  - `#scenes(sku:, device:) -> Array<Hash>` each `{"name"=>..., "value"=>{"id"=>..,"paramId"=>..}}` from `/device/scenes`.
  - `#control(sku:, device:, type:, instance:, value:) -> Boolean` (true on body `code==200`).
  - `Govees::PlatformApi::Error < StandardError`.
- Behavior: raises `Error` on transport failure or body `code != 200`; never raises for an offline device (caller decides).

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/platform_api_test.rb
require "test_helper"
require "govees/platform_api"

class GoveesPlatformApiTest < ActiveSupport::TestCase
  BASE = "https://openapi.api.govee.com"

  setup { @api = Govees::PlatformApi.new(api_key: "k-123") }

  test "devices returns the data array and sends the api key header" do
    stub = stub_request(:get, "#{BASE}/router/api/v1/user/devices")
      .with(headers: { "Govee-API-Key" => "k-123" })
      .to_return(status: 200, body: JSON.generate("code" => 200, "message" => "success",
        "data" => [ { "sku" => "H60B0", "device" => "AA", "deviceName" => "Up" } ]))
    devices = @api.devices
    assert_equal "H60B0", devices.first["sku"]
    assert_requested stub
  end

  test "state flattens capabilities into an instance=>value hash" do
    stub_request(:post, "#{BASE}/router/api/v1/device/state")
      .to_return(status: 200, body: JSON.generate("code" => 200, "payload" => { "capabilities" => [
        { "instance" => "powerSwitch", "state" => { "value" => 1 } },
        { "instance" => "online",      "state" => { "value" => true } },
        { "instance" => "rippleLightToggle", "state" => { "value" => 0 } } ] }))
    st = @api.state(sku: "H60B0", device: "AA")
    assert_equal 1, st["powerSwitch"]
    assert_equal true, st["online"]
    assert_equal 0, st["rippleLightToggle"]
  end

  test "control returns true on body code 200" do
    stub_request(:post, "#{BASE}/router/api/v1/device/control")
      .to_return(status: 200, body: JSON.generate("code" => 200, "msg" => "success"))
    assert_equal true,
      @api.control(sku: "H60B0", device: "AA", type: "devices.capabilities.on_off",
                   instance: "powerSwitch", value: 1)
  end

  test "raises Error when the body code is not 200" do
    stub_request(:get, "#{BASE}/router/api/v1/user/devices")
      .to_return(status: 200, body: JSON.generate("code" => 401, "message" => "bad key"))
    assert_raises(Govees::PlatformApi::Error) { @api.devices }
  end

  test "raises Error on HTTP 5xx" do
    stub_request(:get, "#{BASE}/router/api/v1/user/devices").to_return(status: 500, body: "boom")
    assert_raises(Govees::PlatformApi::Error) { @api.devices }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/platform_api_test.rb`
Expected: FAIL with `cannot load such file -- govees/platform_api`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/platform_api.rb
require "json"
require "net/http"
require "uri"
require "securerandom"

module Govees
  # Govee Platform API (documented, API-key only). Status codes are in the JSON
  # body, not the HTTP status. Raises Error on transport or body-code failure.
  class PlatformApi
    class Error < StandardError; end

    BASE = "https://openapi.api.govee.com"

    def initialize(api_key:, http: Net::HTTP, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @api_key = api_key
      @http    = http
      @clock   = clock
    end

    def devices
      body = get("/router/api/v1/user/devices")
      Array(body["data"])
    end

    def state(sku:, device:)
      body = post("/router/api/v1/device/state", payload: { "sku" => sku, "device" => device })
      caps = body.dig("payload", "capabilities") || []
      caps.each_with_object({}) { |c, h| h[c["instance"]] = c.dig("state", "value") }
    end

    def scenes(sku:, device:)
      body = post("/router/api/v1/device/scenes", payload: { "sku" => sku, "device" => device })
      Array(body.dig("payload", "capabilities", 0, "parameters", "options"))
    end

    def control(sku:, device:, type:, instance:, value:)
      post("/router/api/v1/device/control",
           payload: { "sku" => sku, "device" => device,
                      "capability" => { "type" => type, "instance" => instance, "value" => value } })
      true
    end

    private

    def get(path)  = request(Net::HTTP::Get.new(uri(path)))
    def post(path, payload:)
      req = Net::HTTP::Post.new(uri(path))
      req.body = JSON.generate("requestId" => SecureRandom.uuid, "payload" => payload)
      request(req)
    end

    def uri(path) = URI.join(BASE, path)

    def request(req)
      req["Govee-API-Key"] = @api_key
      req["Content-Type"]  = "application/json"
      u = req.uri
      res = @http.start(u.host, u.port, use_ssl: true) { |h| h.request(req) }
      raise Error, "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)
      body = JSON.parse(res.body)
      raise Error, "code #{body['code']}: #{body['message'] || body['msg']}" unless body["code"].to_i == 200
      body
    rescue JSON::ParserError => e
      raise Error, "invalid JSON: #{e.message}"
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees/platform_api_test.rb`
Expected: PASS (5 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/platform_api.rb test/govees/platform_api_test.rb
git commit -m "feat(govees): Platform API client (devices/state/scenes/control)"
```

---

## Task 3: `Govees::Device` + `Govees::DeviceRegistry`

**Files:**
- Create: `lib/govees/device.rb`, `lib/govees/device_registry.rb`
- Test: `test/govees/device_registry_test.rb`

**Interfaces:**
- Consumes: `Govees::PlatformApi` (`#devices`, `#scenes`), `Light::ZONE_META` (zone-key whitelist, DRY single source), `Govees::LanClient.parse_scan` results.
- Produces:
  - `Govees::Device = Struct.new(:key, :api_id, :sku, :name, :ip, :supports_color, :supports_color_temp, :zones, :scenes, :scene_index, :power_only, keyword_init: true)` where `key` = `api_id` colons-stripped/upcased, `zones` = Array<String> (zone instance keys), `scenes` = Array<String> (names), `scene_index` = Hash name → `{id:, param_id:}`.
  - `Govees::DeviceRegistry.new(api:, logger:)`
  - `#refresh! -> Array<Device>` (calls API, builds devices, caches them).
  - `#all -> Array<Device>`, `#find(key) -> Device | nil`, `#find_by_mac(mac) -> Device | nil`.
  - `#record_lan_ip(mac, ip)` — sets `Device#ip` for the device whose api_id matches `mac` (colon-insensitive).
  - `Govees::DeviceRegistry.normalize_mac(s) -> String` (strip non-alphanumerics, upcase).

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/device_registry_test.rb
require "test_helper"
require "govees/device_registry"

class GoveesDeviceRegistryTest < ActiveSupport::TestCase
  # Minimal fake API returning canned device + scene data.
  class FakeApi
    def devices
      [ { "sku" => "H60B0", "device" => "14:AB:DB:48:44:06:4B:60", "deviceName" => "Uplighter",
          "capabilities" => [
            { "type" => "devices.capabilities.color_setting",  "instance" => "colorRgb" },
            { "type" => "devices.capabilities.color_setting",  "instance" => "colorTemperatureK" },
            { "type" => "devices.capabilities.toggle",         "instance" => "rippleLightToggle" },
            { "type" => "devices.capabilities.toggle",         "instance" => "dreamViewToggle" },
            { "type" => "devices.capabilities.segment_color_setting", "instance" => "segmentedColorRgb" } ] },
        { "sku" => "DreamViewScenic", "device" => "13955275", "deviceName" => "Abendrot",
          "capabilities" => [ { "type" => "devices.capabilities.on_off", "instance" => "powerSwitch" } ] } ]
    end
    def scenes(sku:, device:)
      [ { "name" => "Sunset", "value" => { "id" => 5, "paramId" => 9 } } ]
    end
  end

  setup { @reg = Govees::DeviceRegistry.new(api: FakeApi.new, logger: Logger.new(IO::NULL)) }

  test "refresh builds a device with colon-stripped key and capability flags" do
    @reg.refresh!
    d = @reg.find("14ABDB4844064B60")
    assert_equal "14:AB:DB:48:44:06:4B:60", d.api_id
    assert_equal "H60B0", d.sku
    assert_equal "Uplighter", d.name
    assert d.supports_color
    assert d.supports_color_temp
  end

  test "zones keep only Light::ZONE_META instances (segments and control toggles dropped)" do
    @reg.refresh!
    d = @reg.find("14ABDB4844064B60")
    assert_equal [ "rippleLightToggle" ], d.zones
  end

  test "scenes expose names and an internal id/paramId index" do
    @reg.refresh!
    d = @reg.find("14ABDB4844064B60")
    assert_equal [ "Sunset" ], d.scenes
    assert_equal({ id: 5, param_id: 9 }, d.scene_index["Sunset"])
  end

  test "power_only device is flagged and gets no zones or scenes" do
    @reg.refresh!
    d = @reg.find("13955275")
    assert d.power_only
    assert_empty d.zones
  end

  test "record_lan_ip matches by colon-insensitive mac" do
    @reg.refresh!
    @reg.record_lan_ip("14:AB:DB:48:44:06:4B:60", "192.168.8.184")
    assert_equal "192.168.8.184", @reg.find("14ABDB4844064B60").ip
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/device_registry_test.rb`
Expected: FAIL with `cannot load such file -- govees/device_registry`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/device.rb
module Govees
  Device = Struct.new(:key, :api_id, :sku, :name, :ip,
                      :supports_color, :supports_color_temp,
                      :zones, :scenes, :scene_index, :power_only, keyword_init: true)
end
```

```ruby
# lib/govees/device_registry.rb
require "govees/device"

module Govees
  # Builds the canonical lamp list from the Platform API (authoritative for
  # id/sku/name/capabilities/scenes) and curates it: segments dropped, zones
  # limited to Light::ZONE_META keys, scenes reduced to names + an internal
  # name->{id,paramId} index. LAN discovery only contributes the IP.
  class DeviceRegistry
    def initialize(api:, logger:)
      @api    = api
      @logger = logger
      @by_key = {}
    end

    def self.normalize_mac(str) = str.to_s.gsub(/[^0-9A-Za-z]/, "").upcase

    def refresh!
      @api.devices.each do |raw|
        device = build(raw)
        next unless device
        # Preserve a previously discovered LAN IP across refreshes.
        device.ip = @by_key[device.key]&.ip
        @by_key[device.key] = device
      end
      all
    rescue => e
      @logger.warn("Govees::DeviceRegistry: refresh failed: #{e.class}: #{e.message}")
      all
    end

    def all          = @by_key.values
    def find(key)    = @by_key[key]
    def find_by_mac(mac) = @by_key[self.class.normalize_mac(mac)]

    def record_lan_ip(mac, ip)
      d = find_by_mac(mac)
      d.ip = ip if d
    end

    private

    def build(raw)
      api_id = raw["device"].to_s
      return nil if api_id.empty?
      caps      = Array(raw["capabilities"])
      instances = caps.map { |c| c["instance"] }
      power_only = instances == [ "powerSwitch" ]
      zones = instances & Light::ZONE_META.keys
      scenes, index = power_only ? [ [], {} ] : load_scenes(raw)

      Device.new(
        key: self.class.normalize_mac(api_id), api_id: api_id, sku: raw["sku"].to_s,
        name: raw["deviceName"].to_s, ip: nil,
        supports_color:      instances.include?("colorRgb"),
        supports_color_temp: instances.include?("colorTemperatureK"),
        zones: zones, scenes: scenes, scene_index: index, power_only: power_only)
    end

    def load_scenes(raw)
      options = @api.scenes(sku: raw["sku"], device: raw["device"])
      names = []
      index = {}
      Array(options).each do |opt|
        name = opt["name"].to_s
        next if name.empty?
        names << name
        index[name] = { id: opt.dig("value", "id"), param_id: opt.dig("value", "paramId") }
      end
      [ names, index ]
    rescue => e
      @logger.warn("Govees::DeviceRegistry: scenes for #{raw['device']} failed: #{e.message}")
      [ [], {} ]
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees/device_registry_test.rb`
Expected: PASS (5 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/device.rb lib/govees/device_registry.rb test/govees/device_registry_test.rb
git commit -m "feat(govees): device registry (API-authoritative, curated zones/scenes)"
```

---

## Task 4: `Govees::StateStore` — optimistic state + conflict resolution

This is the heart of the bridge. Pure logic, no I/O.

**Files:**
- Create: `lib/govees/state_store.rb`
- Test: `test/govees/state_store_test.rb`

**Interfaces:**
- Produces:
  - `Govees::StateStore.new(pending_window_s: 5.0, clock: ...)`
  - `#record_command(key, changes) -> Hash` — merges `changes` into desired, marks `PENDING` until `now+window`, returns the new published state.
  - `#apply_telemetry(key, telemetry, source:) -> {published:, changed:, needs_api_clarification:}` where `source` is `:lan` or `:api`. Implements: during pending, deviations are "not applied yet" (ignored) and a match confirms → `SYNCED`; off is adopted immediately; on+deviation from a `:lan` source requests API clarification; `:api` telemetry is adopted as authoritative.
  - `#published(key) -> Hash | nil`, `#status(key) -> :synced | :pending | :reconciling | nil`.
  - State Hash shape: `{ on:, brightness:, color: {r:,g:,b:}|nil, color_temp_k:|nil, reachable:, zone_states: {} }` (keys present only when known).

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/state_store_test.rb
require "test_helper"
require "govees/state_store"

class GoveesStateStoreTest < ActiveSupport::TestCase
  setup do
    @now   = 1000.0
    @store = Govees::StateStore.new(pending_window_s: 5.0, clock: -> { @now })
  end

  test "record_command publishes optimistically and marks pending" do
    pub = @store.record_command("K", on: true, brightness: 50)
    assert_equal true, pub[:on]
    assert_equal 50, pub[:brightness]
    assert_equal :pending, @store.status("K")
  end

  test "matching lan read-back within window confirms to synced" do
    @store.record_command("K", on: true, brightness: 50)
    res = @store.apply_telemetry("K", { on: true, brightness: 50, reachable: true }, source: :lan)
    assert_equal :synced, @store.status("K")
    refute res[:needs_api_clarification]
  end

  test "deviating lan read-back within window is ignored as not-yet-applied" do
    @store.record_command("K", on: true, brightness: 50)
    res = @store.apply_telemetry("K", { on: true, brightness: 10, reachable: true }, source: :lan)
    assert_equal 50, @store.published("K")[:brightness], "optimistic value held"
    assert_equal :pending, @store.status("K")
    refute res[:needs_api_clarification]
  end

  test "off telemetry is adopted immediately even against an on optimistic state" do
    @store.record_command("K", on: true, brightness: 50)
    @now += 10 # past the pending window
    res = @store.apply_telemetry("K", { on: false, reachable: true }, source: :lan)
    assert_equal false, @store.published("K")[:on]
    assert_equal :synced, @store.status("K")
    refute res[:needs_api_clarification]
  end

  test "on+deviation from lan after window requests api clarification" do
    @store.record_command("K", on: true, brightness: 50)
    @now += 10
    res = @store.apply_telemetry("K", { on: true, brightness: 80, reachable: true }, source: :lan)
    assert res[:needs_api_clarification]
    assert_equal :reconciling, @store.status("K")
  end

  test "api telemetry is authoritative and adopted" do
    @store.record_command("K", on: true, brightness: 50)
    @now += 10
    @store.apply_telemetry("K", { on: true, brightness: 80, reachable: true }, source: :lan)
    res = @store.apply_telemetry("K", { on: true, brightness: 80, color_temp_k: 3000,
                                        reachable: true, zone_states: { "ripple" => true } }, source: :api)
    assert_equal 80, @store.published("K")[:brightness]
    assert_equal({ "ripple" => true }, @store.published("K")[:zone_states])
    assert_equal :synced, @store.status("K")
    refute res[:needs_api_clarification]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/state_store_test.rb`
Expected: FAIL with `cannot load such file -- govees/state_store`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/state_store.rb
module Govees
  # Per-lamp desired/confirmed state + conflict resolution. Pure logic, no I/O.
  #
  # Rules:
  #  - record_command: set desired optimistically, status PENDING for a window.
  #  - During PENDING, a LAN reading that matches desired confirms (SYNCED);
  #    one that deviates is treated as "not yet applied" and ignored.
  #  - After the window (or when not pending): off is adopted immediately;
  #    on+deviation from a :lan source flags needs_api_clarification (RECONCILING);
  #    :api telemetry is always adopted as the authoritative truth.
  class StateStore
    # Fields compared to decide "deviation" (zone_states/reachable excluded).
    COMPARE = %i[on brightness color color_temp_k].freeze

    Entry = Struct.new(:published, :status, :pending_until, keyword_init: true)

    def initialize(pending_window_s: 5.0, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @window = pending_window_s
      @clock  = clock
      @entries = {}
    end

    def published(key) = @entries[key]&.published&.dup
    def status(key)    = @entries[key]&.status

    def record_command(key, changes)
      entry = (@entries[key] ||= Entry.new(published: {}, status: :synced, pending_until: 0.0))
      entry.published = entry.published.merge(normalize(changes))
      entry.status = :pending
      entry.pending_until = @clock.call + @window
      entry.published.dup
    end

    def apply_telemetry(key, telemetry, source:)
      tel = normalize(telemetry)
      entry = (@entries[key] ||= Entry.new(published: {}, status: :synced, pending_until: 0.0))

      if entry.status == :pending && @clock.call < entry.pending_until
        if matches?(entry.published, tel)
          entry.published = entry.published.merge(tel)
          entry.status = :synced
        end # else: not applied yet -> hold optimistic, ignore
        return result(entry, false)
      end

      if tel[:on] == false
        entry.published = entry.published.merge(tel)
        entry.status = :synced
        return result(entry, false)
      end

      if source == :lan && !matches?(entry.published, tel)
        entry.status = :reconciling
        return result(entry, true)
      end

      entry.published = entry.published.merge(tel)
      entry.status = :synced
      result(entry, false)
    end

    private

    def result(entry, needs_api) = { published: entry.published.dup, changed: true, needs_api_clarification: needs_api }

    # Only the fields present in telemetry are compared; a field absent from the
    # reading never counts as a deviation.
    def matches?(published, tel)
      COMPARE.all? { |f| !tel.key?(f) || published[f] == tel[f] }
    end

    def normalize(h) = h.transform_keys(&:to_sym)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees/state_store_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/state_store.rb test/govees/state_store_test.rb
git commit -m "feat(govees): state store with optimistic/eventually-consistent conflict logic"
```

---

## Task 5: `Govees::CommandRouter` — route `set` verbs to LAN/API

**Files:**
- Create: `lib/govees/command_router.rb`
- Test: `test/govees/command_router_test.rb`

**Interfaces:**
- Consumes: `Govees::DeviceRegistry` (`#find`), `Govees::LanClient`, `Govees::PlatformApi`, `Govees::StateStore` (`#record_command`).
- Produces:
  - `Govees::CommandRouter.new(registry:, lan:, api:, store:, logger:)`
  - `#handle(key, verb) -> Hash | nil` — `verb` is the parsed `set` payload (symbol or string keys). Routes power/brightness/color/color_temp_k via LAN (when an IP is known) else API; zone/scene via API only. Returns the new optimistic published state (from `store.record_command`) or nil if device unknown.
- Routing per the spec table. Power on whole-lamp lamps uses LAN `turn`; if device is `power_only` or has no IP, uses API `powerSwitch`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/command_router_test.rb
require "test_helper"
require "govees/command_router"
require "govees/device"

class GoveesCommandRouterTest < ActiveSupport::TestCase
  class FakeLan
    attr_reader :calls
    def initialize = @calls = []
    def turn(ip, on)          = @calls << [ :turn, ip, on ]
    def brightness(ip, v)     = @calls << [ :brightness, ip, v ]
    def color(ip, r:, g:, b:) = @calls << [ :color, ip, r, g, b ]
    def color_temp(ip, k)     = @calls << [ :color_temp, ip, k ]
    def request_status(ip)    = @calls << [ :status, ip ]
  end

  class FakeApi
    attr_reader :calls
    def initialize = @calls = []
    def control(**kw) = (@calls << kw) && true
  end

  def device(ip:, sku: "H60B0", power_only: false)
    Govees::Device.new(key: "K", api_id: "14:AB", sku: sku, name: "n", ip: ip,
      supports_color: true, supports_color_temp: true, zones: [ "rippleLightToggle" ],
      scenes: [ "Sunset" ], scene_index: { "Sunset" => { id: 5, param_id: 9 } }, power_only: power_only)
  end

  def build(dev)
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_k| dev } }
    @lan = FakeLan.new; @api = FakeApi.new
    @store = Govees::StateStore.new(clock: -> { 0.0 })
    Govees::CommandRouter.new(registry: registry, lan: @lan, api: @api, store: @store,
                              logger: Logger.new(IO::NULL))
  end

  test "brightness on a lan-reachable lamp goes over LAN and records optimistic state" do
    router = build(device(ip: "1.2.3.4"))
    pub = router.handle("K", { "brightness" => 40 })
    assert_includes @lan.calls, [ :brightness, "1.2.3.4", 40 ]
    assert_equal 40, pub[:brightness]
  end

  test "power falls back to API powerSwitch when no LAN ip is known" do
    router = build(device(ip: nil))
    router.handle("K", { "power" => "on" })
    assert_equal "powerSwitch", @api.calls.first[:instance]
    assert_equal 1, @api.calls.first[:value]
  end

  test "zone toggle always goes over the API" do
    router = build(device(ip: "1.2.3.4"))
    router.handle("K", { "zone" => { "name" => "rippleLightToggle", "on" => true } })
    assert_equal "rippleLightToggle", @api.calls.first[:instance]
    assert_equal 1, @api.calls.first[:value]
    assert_empty @lan.calls.reject { |c| c.first == :status }
  end

  test "scene resolves name to id/paramId and controls via API lightScene" do
    router = build(device(ip: "1.2.3.4"))
    router.handle("K", { "scene" => "Sunset" })
    call = @api.calls.first
    assert_equal "lightScene", call[:instance]
    assert_equal({ "id" => 5, "paramId" => 9 }, call[:value])
  end

  test "unknown device returns nil" do
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_k| nil } }
    router = Govees::CommandRouter.new(registry: registry, lan: FakeLan.new, api: FakeApi.new,
      store: Govees::StateStore.new(clock: -> { 0.0 }), logger: Logger.new(IO::NULL))
    assert_nil router.handle("X", { "power" => "on" })
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/command_router_test.rb`
Expected: FAIL with `cannot load such file -- govees/command_router`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/command_router.rb
module Govees
  # Translates one parsed `govees/<id>/set` verb into a LAN or API call per
  # capability, and records the optimistic state. Power/brightness/colour/temp
  # prefer LAN (when an IP is known); zones and scenes are API-only.
  class CommandRouter
    ON_OFF = "devices.capabilities.on_off".freeze
    TOGGLE = "devices.capabilities.toggle".freeze
    SCENE  = "devices.capabilities.dynamic_scene".freeze

    def initialize(registry:, lan:, api:, store:, logger:)
      @registry = registry; @lan = lan; @api = api; @store = store; @logger = logger
    end

    def handle(key, verb)
      device = @registry.find(key)
      return @logger.warn("Govees::CommandRouter: unknown device #{key}") || nil unless device
      verb = verb.transform_keys(&:to_s)

      changes =
        if verb.key?("power")       then power(device, verb["power"].to_s == "on")
        elsif verb.key?("brightness") then brightness(device, verb["brightness"].to_i)
        elsif verb.key?("color")    then color(device, verb["color"])
        elsif verb.key?("color_temp_k") then color_temp(device, verb["color_temp_k"].to_i)
        elsif verb.key?("zone")     then zone(device, verb["zone"])
        elsif verb.key?("scene")    then scene(device, verb["scene"].to_s)
        else return @logger.warn("Govees::CommandRouter: unknown verb #{verb.keys}") || nil
        end

      @store.record_command(key, changes)
    end

    private

    def lan?(device) = device.ip && !device.power_only

    def power(device, on)
      if lan?(device)
        @lan.turn(device.ip, on); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: ON_OFF, instance: "powerSwitch", value: on ? 1 : 0)
      end
      { on: on }
    end

    def brightness(device, value)
      if lan?(device)
        @lan.brightness(device.ip, value); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: "devices.capabilities.range", instance: "brightness", value: value)
      end
      { on: true, brightness: value }
    end

    def color(device, rgb)
      rgb = rgb.transform_keys(&:to_s)
      r, g, b = rgb["r"].to_i, rgb["g"].to_i, rgb["b"].to_i
      if lan?(device)
        @lan.color(device.ip, r: r, g: g, b: b); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: "devices.capabilities.color_setting",
                     instance: "colorRgb", value: (r << 16) | (g << 8) | b)
      end
      { on: true, color: { r: r, g: g, b: b }, color_temp_k: nil }
    end

    def color_temp(device, kelvin)
      if lan?(device)
        @lan.color_temp(device.ip, kelvin); @lan.request_status(device.ip)
      else
        @api.control(sku: device.sku, device: device.api_id, type: "devices.capabilities.color_setting",
                     instance: "colorTemperatureK", value: kelvin)
      end
      { on: true, color_temp_k: kelvin, color: nil }
    end

    def zone(device, spec)
      spec = spec.transform_keys(&:to_s)
      name = spec["name"].to_s
      on   = spec["on"] ? true : false
      @api.control(sku: device.sku, device: device.api_id, type: TOGGLE, instance: name, value: on ? 1 : 0)
      { zone_states: { name => on } }
    end

    def scene(device, name)
      entry = device.scene_index[name]
      return {} unless entry
      @api.control(sku: device.sku, device: device.api_id, type: SCENE, instance: "lightScene",
                   value: { "id" => entry[:id], "paramId" => entry[:param_id] })
      { on: true }
    end
  end
end
```

Note: the zone-change shape `{ zone_states: { name => on } }` is merged into the published state by `StateStore#record_command`; `StateStore` does a shallow merge, which replaces the whole `zone_states` hash, so the router only includes the one changed zone. **Step 3a:** confirm by reading `StateStore#record_command` — if zone bits must accumulate, merge against the existing published `zone_states` here before recording. Add this test and make it pass:

```ruby
  test "zone command preserves other zone bits" do
    router = build(device(ip: "1.2.3.4"))
    @store.record_command("K", zone_states: { "sideLightToggle" => true })
    router.handle("K", { "zone" => { "name" => "rippleLightToggle", "on" => true } })
    assert_equal({ "sideLightToggle" => true, "rippleLightToggle" => true },
                 @store.published("K")[:zone_states])
  end
```

To pass it, in `#zone` build the merged hash from `@store.published(device.key)`:

```ruby
    def zone(device, spec)
      spec = spec.transform_keys(&:to_s)
      name = spec["name"].to_s
      on   = spec["on"] ? true : false
      @api.control(sku: device.sku, device: device.api_id, type: TOGGLE, instance: name, value: on ? 1 : 0)
      bits = (@store.published(device.key) || {})[:zone_states] || {}
      { zone_states: bits.merge(name => on) }
    end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/govees/command_router_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/command_router.rb test/govees/command_router_test.rb
git commit -m "feat(govees): command router (LAN/API per capability, optimistic record)"
```

---

## Task 6: `Govees::Reconciler` — poll ticks + on-demand clarification

**Files:**
- Create: `lib/govees/reconciler.rb`
- Test: `test/govees/reconciler_test.rb`

**Interfaces:**
- Consumes: `Govees::DeviceRegistry`, `Govees::LanClient`, `Govees::PlatformApi`, `Govees::StateStore`.
- Produces:
  - `Govees::Reconciler.new(registry:, lan:, api:, store:, logger:)`
  - `#lan_tick -> Array<[key, result]>` — for each device with a known IP, request `devStatus` (handled async via the listener; see Bridge) — **but** for testability `lan_tick` here pulls cached LAN status through an injected reader. To keep this unit pure, model it as: `#apply_lan(key, status_struct)` converts a `LanClient::Status` to a telemetry hash and calls `store.apply_telemetry(..., source: :lan)`; when it returns `needs_api_clarification`, immediately `#clarify(key)`.
  - `#api_tick -> Array<[key, result]>` — for each device, call `api.state`, convert to telemetry, `store.apply_telemetry(..., source: :api)`.
  - `#clarify(key)` — single `api.state` → telemetry → `apply_telemetry(source: :api)`.
  - `Govees::Reconciler.lan_to_telemetry(status) -> Hash` and `.api_to_telemetry(state_hash, device) -> Hash` (class methods, pure, unit-tested directly).

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/reconciler_test.rb
require "test_helper"
require "govees/reconciler"
require "govees/lan_client"
require "govees/device"

class GoveesReconcilerTest < ActiveSupport::TestCase
  def device(zones: [ "rippleLightToggle" ])
    Govees::Device.new(key: "K", api_id: "14:AB", sku: "H60B0", name: "n", ip: "1.2.3.4",
      supports_color: true, supports_color_temp: true, zones: zones,
      scenes: [], scene_index: {}, power_only: false)
  end

  test "lan_to_telemetry maps a Status struct" do
    s = Govees::LanClient::Status.new(on: true, brightness: 30, color_r: 1, color_g: 2, color_b: 3,
                                      color_temp_k: 0, sku: "H60B0")
    t = Govees::Reconciler.lan_to_telemetry(s)
    assert_equal true, t[:on]
    assert_equal 30, t[:brightness]
    assert_equal({ r: 1, g: 2, b: 3 }, t[:color])
    assert_equal true, t[:reachable]
  end

  test "api_to_telemetry maps power/brightness/colour/online and zone bits" do
    state = { "powerSwitch" => 1, "brightness" => 70, "colorTemperatureK" => 3000, "colorRgb" => 0,
              "online" => true, "rippleLightToggle" => 1 }
    t = Govees::Reconciler.api_to_telemetry(state, device)
    assert_equal true, t[:on]
    assert_equal 70, t[:brightness]
    assert_equal 3000, t[:color_temp_k]
    assert_equal true, t[:reachable]
    assert_equal({ "rippleLightToggle" => true }, t[:zone_states])
  end

  test "apply_lan that needs clarification triggers an immediate api state call" do
    store = Govees::StateStore.new(pending_window_s: 0.0, clock: -> { 100.0 })
    store.record_command("K", on: true, brightness: 50)
    api_calls = []
    api = Object.new
    api.define_singleton_method(:state) { |sku:, device:| api_calls << device; { "powerSwitch" => 1, "brightness" => 80, "online" => true } }
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_| device } ; r.define_singleton_method(:all) { [ device ] } }
    rec = Govees::Reconciler.new(registry: registry, lan: nil, api: api, store: store, logger: Logger.new(IO::NULL))
    rec.apply_lan("K", Govees::LanClient::Status.new(on: true, brightness: 80, color_temp_k: 0))
    assert_equal [ "14:AB" ], api_calls
    assert_equal 80, store.published("K")[:brightness]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/reconciler_test.rb`
Expected: FAIL with `cannot load such file -- govees/reconciler`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/reconciler.rb
module Govees
  # Drives reconcile: LAN devStatus readings (fast) and API polls (slow, richer).
  # Pure mapping helpers are class methods; instance methods wire them to the
  # store and trigger API clarification when a LAN reading deviates.
  class Reconciler
    def initialize(registry:, lan:, api:, store:, logger:)
      @registry = registry; @lan = lan; @api = api; @store = store; @logger = logger
    end

    def self.lan_to_telemetry(status)
      t = { on: status.on, reachable: true }
      t[:brightness] = status.brightness unless status.brightness.nil?
      if status.color_temp_k.to_i.positive?
        t[:color_temp_k] = status.color_temp_k
      elsif status.color_r
        t[:color] = { r: status.color_r, g: status.color_g, b: status.color_b }
      end
      t
    end

    def self.api_to_telemetry(state, device)
      t = { on: state["powerSwitch"].to_i == 1, reachable: state.fetch("online", true) ? true : false }
      t[:brightness] = state["brightness"] if state.key?("brightness")
      if state["colorRgb"].to_i.positive?
        rgb = state["colorRgb"].to_i
        t[:color] = { r: (rgb >> 16) & 0xFF, g: (rgb >> 8) & 0xFF, b: rgb & 0xFF }
      elsif state["colorTemperatureK"].to_i.positive?
        t[:color_temp_k] = state["colorTemperatureK"]
      end
      zones = device.zones.each_with_object({}) do |z, h|
        v = state[z]
        h[z] = (v.to_i == 1) unless v.nil? || v == ""
      end
      t[:zone_states] = zones unless zones.empty?
      t
    end

    # Called when a LAN devStatus reply for `key` arrives (via the Bridge listener).
    def apply_lan(key, status)
      res = @store.apply_telemetry(key, self.class.lan_to_telemetry(status), source: :lan)
      clarify(key) if res[:needs_api_clarification]
      res
    end

    # Periodic full reconcile against the API.
    def api_tick
      @registry.all.map do |device|
        state = @api.state(sku: device.sku, device: device.api_id)
        [ device.key, @store.apply_telemetry(device.key, self.class.api_to_telemetry(state, device), source: :api) ]
      rescue => e
        @logger.warn("Govees::Reconciler: api_tick #{device.key}: #{e.message}")
        [ device.key, nil ]
      end
    end

    def clarify(key)
      device = @registry.find(key)
      return unless device
      state = @api.state(sku: device.sku, device: device.api_id)
      @store.apply_telemetry(key, self.class.api_to_telemetry(state, device), source: :api)
    rescue => e
      @logger.warn("Govees::Reconciler: clarify #{key}: #{e.message}")
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees/reconciler_test.rb`
Expected: PASS (3 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/reconciler.rb test/govees/reconciler_test.rb
git commit -m "feat(govees): reconciler (LAN/API telemetry mapping + clarification)"
```

---

## Task 7: `Govees::Bridge` — orchestrator (threads, MQTT, publish)

**Files:**
- Create: `lib/govees/bridge.rb`
- Test: `test/govees/bridge_test.rb`

**Interfaces:**
- Consumes: all of the above + `mqtt_config` (`.host`, `.port`), `govee_config` (`.lan_poll_seconds`, `.api_poll_seconds`, `.pending_window_seconds`), `Govees::PlatformApi`.
- Produces:
  - `Govees::Bridge.new(mqtt_config:, govee_config:, api:, logger:, lan: ..., registry: ..., store: ..., router: ..., reconciler: ..., mqtt_factory: ..., clock: ...)` — all collaborators injectable; sensible defaults wired from the configs.
  - `#publish_config(device)` → retained `govees/<key>/config`.
  - `#publish_state(key, state)` → retained `govees/<key>/state`.
  - `#on_set(key, payload_string)` → parses JSON verb, calls `router.handle`, publishes resulting state.
  - `#run` / `#stop!` (supervised threads: command-subscribe, LAN listener, LAN poller, API poller). Mirrors `GoveeMqttBridge` thread/stop structure.
- For the unit test we exercise the pure seams (`#on_set`, `#publish_state`) with a fake MQTT publisher; the thread loops reuse the proven `sleep_interruptible` pattern and are smoke-checked in Task 13.

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees/bridge_test.rb
require "test_helper"
require "govees/bridge"
require "govees/device"

class GoveesBridgeTest < ActiveSupport::TestCase
  class FakePublisher
    attr_reader :published
    def initialize = @published = []
    def connect = self
    def publish(topic, payload, retain: false) = @published << { topic: topic, payload: payload, retain: retain }
    def disconnect = nil
  end

  def device
    Govees::Device.new(key: "K", api_id: "14:AB", sku: "H60B0", name: "Uplighter", ip: "1.2.3.4",
      supports_color: true, supports_color_temp: true, zones: [ "rippleLightToggle" ],
      scenes: [ "Sunset" ], scene_index: { "Sunset" => { id: 5, param_id: 9 } }, power_only: false)
  end

  def build
    @pub = FakePublisher.new
    registry = Object.new.tap { |r| r.define_singleton_method(:find) { |_| device } }
    store = Govees::StateStore.new(clock: -> { 0.0 })
    router = Object.new
    router.define_singleton_method(:handle) { |_k, _v| { on: true, brightness: 60 } }
    mqtt = Struct.new(:host, :port).new("h", 1883)
    cfg  = Struct.new(:lan_poll_seconds, :api_poll_seconds, :pending_window_seconds).new(5, 180, 5)
    Govees::Bridge.new(mqtt_config: mqtt, govee_config: cfg, api: nil, logger: Logger.new(IO::NULL),
      registry: registry, store: store, router: router, reconciler: nil,
      mqtt_factory: -> { @pub })
  end

  test "publish_config emits a retained config payload with curated fields" do
    bridge = build
    bridge.publish_config(device)
    msg = @pub.published.find { |m| m[:topic] == "govees/K/config" }
    data = JSON.parse(msg[:payload])
    assert msg[:retain]
    assert_equal "H60B0", data["sku"]
    assert_equal [ "rippleLightToggle" ], data["zones"]
    assert_equal [ "Sunset" ], data["scenes"]
  end

  test "on_set routes the verb and publishes the resulting state" do
    bridge = build
    bridge.on_set("K", JSON.generate("brightness" => 60))
    msg = @pub.published.find { |m| m[:topic] == "govees/K/state" }
    assert_equal 60, JSON.parse(msg[:payload])["brightness"]
  end

  test "on_set ignores invalid JSON without raising" do
    bridge = build
    assert_nothing_raised { bridge.on_set("K", "not-json{") }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees/bridge_test.rb`
Expected: FAIL with `cannot load such file -- govees/bridge`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees/bridge.rb
require "mqtt"
require "json"
require "socket"
require "govees/lan_client"
require "govees/platform_api"
require "govees/device_registry"
require "govees/state_store"
require "govees/command_router"
require "govees/reconciler"

module Govees
  # Orchestrates the govees bridge: owns one MQTT publisher + a command
  # subscriber, the LAN listener/poller and the API poller threads, and the
  # collaborators. Publishes govees/<key>/{config,state}; consumes govees/<key>/set.
  class Bridge
    CONFIG_TOPIC = "govees/%s/config".freeze
    STATE_TOPIC  = "govees/%s/state".freeze
    SET_FILTER   = "govees/+/set".freeze

    def initialize(mqtt_config:, govee_config:, api:, logger:,
                   lan: nil, registry: nil, store: nil, router: nil, reconciler: nil,
                   mqtt_factory: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @mqtt_config = mqtt_config
      @cfg         = govee_config
      @logger      = logger
      @clock       = clock
      @stopping    = false
      @lan       = lan       || LanClient.new
      @registry  = registry  || DeviceRegistry.new(api: api, logger: logger)
      @store     = store     || StateStore.new(pending_window_s: govee_config.pending_window_seconds, clock: clock)
      @router    = router    || CommandRouter.new(registry: @registry, lan: @lan, api: api, store: @store, logger: logger)
      @reconciler = reconciler || Reconciler.new(registry: @registry, lan: @lan, api: api, store: @store, logger: logger)
      @mqtt_factory = mqtt_factory || -> { MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port) }
      @publisher = nil
      @command_client = nil
      @listener_socket = nil
    end

    def publish_config(device)
      payload = JSON.generate(
        "sku" => device.sku, "name" => device.name,
        "supports_color" => device.supports_color, "supports_color_temp" => device.supports_color_temp,
        "zones" => device.zones, "scenes" => device.scenes)
      publisher.publish(format(CONFIG_TOPIC, device.key), payload, retain: true)
    end

    def publish_state(key, state)
      publisher.publish(format(STATE_TOPIC, key), JSON.generate(state), retain: true)
    end

    def on_set(key, payload_string)
      verb  = JSON.parse(payload_string)
      state = @router.handle(key, verb)
      publish_state(key, state) if state
    rescue JSON::ParserError => e
      @logger.warn("Govees::Bridge: invalid set JSON for #{key}: #{e.message}")
    end

    def run
      @registry.refresh!
      @registry.all.each { |d| publish_config(d); @lan.request_status(d.ip) if d.ip }
      threads = [ command_thread, listener_thread, lan_poller_thread, api_poller_thread ]
      threads.each(&:join)
    ensure
      begin; @publisher&.disconnect; rescue StandardError; nil; end
    end

    def stop!
      @stopping = true
      begin; @listener_socket&.close; rescue StandardError; nil; end
      begin; @command_client&.disconnect; rescue StandardError; nil; end
    end

    private

    def publisher
      @publisher ||= begin
        c = @mqtt_factory.call; c.connect; c
      end
    end

    def command_thread
      Thread.new do
        Thread.current.name = "govees_command"
        @command_client = @mqtt_factory.call
        @command_client.connect
        @command_client.subscribe(SET_FILTER)
        @command_client.get { |topic, payload| on_set(topic.split("/")[1], payload) }
      rescue => e
        @logger.error("Govees::Bridge command: #{e.class}: #{e.message}")
      end
    end

    def listener_thread
      Thread.new do
        Thread.current.name = "govees_listener"
        @listener_socket = UDPSocket.new
        @listener_socket.bind("0.0.0.0", LanClient::LISTEN_PORT)
        until @stopping
          payload, addr = @listener_socket.recvfrom(2048)
          handle_datagram(payload, addr[3])
        end
      rescue => e
        @logger.error("Govees::Bridge listener: #{e.class}: #{e.message}") unless @stopping
      end
    end

    # A datagram is either a scan reply (registers IP) or a devStatus reply.
    def handle_datagram(payload, sender_ip)
      if (scan = LanClient.parse_scan(payload))
        @registry.record_lan_ip(scan[:mac], scan[:ip])
        return
      end
      status = LanClient.parse_status(payload)
      return unless status
      device = @registry.all.find { |d| d.ip == sender_ip }
      return unless device
      res = @reconciler.apply_lan(device.key, status)
      publish_state(device.key, res[:published]) if res
    end

    def lan_poller_thread
      Thread.new do
        Thread.current.name = "govees_lan_poller"
        until @stopping
          @registry.all.each { |d| @lan.request_status(d.ip) if d.ip }
          sleep_interruptible(@cfg.lan_poll_seconds)
        end
      rescue => e
        @logger.error("Govees::Bridge lan_poller: #{e.message}")
      end
    end

    def api_poller_thread
      Thread.new do
        Thread.current.name = "govees_api_poller"
        until @stopping
          sleep_interruptible(@cfg.api_poll_seconds)
          break if @stopping
          @reconciler.api_tick.each { |key, res| publish_state(key, res[:published]) if res }
        end
      rescue => e
        @logger.error("Govees::Bridge api_poller: #{e.message}")
      end
    end

    def sleep_interruptible(seconds)
      deadline = Time.now + seconds
      sleep([ deadline - Time.now, 1 ].min) while Time.now < deadline && !@stopping
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees/bridge_test.rb`
Expected: PASS (3 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees/bridge.rb test/govees/bridge_test.rb
git commit -m "feat(govees): bridge orchestrator (threads, MQTT publish/subscribe)"
```

---

## Task 8: Config — `govee:` section in ConfigLoader

**Files:**
- Modify: `lib/config_loader.rb`
- Modify: `config/ziwoas.example.yml`
- Modify: `config/ziwoas.test.yml` (add a `govee:` block so the loader test fixtures exercise it)
- Test: `test/config_loader_test.rb` (append cases)

**Interfaces:**
- Produces: `GoveeCfg = Struct.new(:api_key, :lan_poll_seconds, :api_poll_seconds, :pending_window_seconds, :names, keyword_init: true)` where `names` is a Hash `key => { name:, room: }` from the yml device map. `Config` gains a `:govee` member. `build_govee(h)` returns `nil` when the block is absent (bridge off), reads `api_key` from `ENV["GOVEE_API_KEY"]` (yml never stores the secret).

- [ ] **Step 1: Write the failing test**

```ruby
# append to test/config_loader_test.rb
  test "govee block parses intervals and device name map, api key from ENV" do
    yaml = <<~YML
      electricity_price_eur_per_kwh: 0.3
      timezone: Europe/Berlin
      mqtt: { host: h, port: 1883, topic_prefix: shellies }
      plugs: []
      govee:
        lan_poll_seconds: 8
        api_poll_seconds: 180
        pending_window_seconds: 5
        devices:
          - { key: 14ABDB4844064B60, name: "Uplighter", room: "Wohnzimmer" }
    YML
    file = Tempfile.new([ "z", ".yml" ]); file.write(yaml); file.flush
    ENV["GOVEE_API_KEY"] = "secret-key"
    cfg = ConfigLoader.load(file.path)
    assert_equal "secret-key", cfg.govee.api_key
    assert_equal 8, cfg.govee.lan_poll_seconds
    assert_equal({ name: "Uplighter", room: "Wohnzimmer" }, cfg.govee.names["14ABDB4844064B60"])
  ensure
    ENV.delete("GOVEE_API_KEY"); file&.close!
  end

  test "absent govee block yields nil (bridge off)" do
    yaml = "electricity_price_eur_per_kwh: 0.3\ntimezone: Europe/Berlin\nmqtt: { host: h, port: 1883, topic_prefix: shellies }\nplugs: []\n"
    file = Tempfile.new([ "z", ".yml" ]); file.write(yaml); file.flush
    assert_nil ConfigLoader.load(file.path).govee
  ensure
    file&.close!
  end
```

(Add `require "tempfile"` at the top of the test file if not already present.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/config_loader_test.rb`
Expected: FAIL (`NoMethodError: undefined method 'govee'` / struct member missing)

- [ ] **Step 3: Write minimal implementation**

In `lib/config_loader.rb`: add the struct, the `Config` member, and `build_govee`.

```ruby
  # add near the other Struct definitions
  GoveeCfg = Struct.new(:api_key, :lan_poll_seconds, :api_poll_seconds,
                        :pending_window_seconds, :names, keyword_init: true)
```

Add `:govee` to the `Config = Struct.new(...)` member list and to the `Config.new(...)` call in `#build` (`govee: build_govee(@raw["govee"])`). Then:

```ruby
  def build_govee(h)
    return nil if h.nil?
    h = require_hash(h, "govee")
    names = Array(h["devices"]).each_with_object({}) do |d, acc|
      key = require_string(d["key"], "govee.devices[].key")
      acc[key] = { name: d["name"].to_s, room: d["room"] }
    end
    GoveeCfg.new(
      api_key:                ENV["GOVEE_API_KEY"].to_s,
      lan_poll_seconds:       (h["lan_poll_seconds"] || 8).to_i,
      api_poll_seconds:       (h["api_poll_seconds"] || 180).to_i,
      pending_window_seconds: (h["pending_window_seconds"] || 5).to_i,
      names:                  names,
    )
  end
```

Add to `config/ziwoas.example.yml`:

```yaml
# Govee lights bridge (LAN-first + Platform API). Omit to disable.
# API key comes from ENV GOVEE_API_KEY (never store the secret here).
# govee:
#   lan_poll_seconds: 8
#   api_poll_seconds: 180
#   pending_window_seconds: 5
#   devices:
#     - key: 14ABDB4844064B60   # MAC, colons stripped, uppercase
#       name: Uplighter
#       room: Wohnzimmer
```

Add a matching uncommented `govee:` block to `config/ziwoas.test.yml`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/config_loader_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/config_loader.rb config/ziwoas.example.yml config/ziwoas.test.yml test/config_loader_test.rb
git commit -m "feat(govees): config loader govee section (intervals, device name map)"
```

---

## Task 9: `GoveesDiscoveryHandler` — consume `govees/<id>/config`

Replaces `govee_discovery_handler.rb` + `govee_zone_discovery_handler.rb`.

**Files:**
- Create: `lib/govees_discovery_handler.rb`
- Test: `test/govees_discovery_handler_test.rb`

**Interfaces:**
- Produces: `GoveesDiscoveryHandler.new(logger:)` with `#subscriptions = ["govees/+/config"]`, `#matches?(topic)`, `#handle(topic, payload)` → upserts `Light` (key from topic, `name` on create only, `sku`, `supports_color`, `supports_color_temp`, `firmware_scenes` from `scenes`, `zones` from `zones`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees_discovery_handler_test.rb
require "test_helper"
require "govees_discovery_handler"

class GoveesDiscoveryHandlerTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    @handler = GoveesDiscoveryHandler.new(logger: Logger.new(IO::NULL))
  end

  test "subscriptions and matches target govees config topics" do
    assert_equal [ "govees/+/config" ], @handler.subscriptions
    assert @handler.matches?("govees/14ABDB4844064B60/config")
    refute @handler.matches?("govees/14ABDB4844064B60/state")
  end

  test "handle upserts a Light with sku, capabilities, scenes and zones" do
    @handler.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Uplighter", "supports_color" => true,
      "supports_color_temp" => true, "zones" => [ "rippleLightToggle" ], "scenes" => [ "Sunset" ]))
    l = Light.find_by(key: "K1")
    assert_equal "H60B0", l.sku
    assert_equal "Uplighter", l.name
    assert l.supports_color
    assert_equal [ "rippleLightToggle" ], l.zones
    assert_equal [ "Sunset" ], l.firmware_scenes
  end

  test "user rename is preserved on later config" do
    Light.create!(key: "K1", name: "Mein Name", zones: [])
    @handler.handle("govees/K1/config", JSON.generate("sku" => "H60B0", "name" => "Uplighter", "zones" => [], "scenes" => []))
    assert_equal "Mein Name", Light.find_by(key: "K1").name
  end

  test "ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("govees/K1/config", "x{") }
    assert_equal 0, Light.count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees_discovery_handler_test.rb`
Expected: FAIL with `cannot load such file -- govees_discovery_handler`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees_discovery_handler.rb
require "json"

# Consumes the govees bridge's retained config (govees/<key>/config) and upserts
# Light rows. Key comes from the topic. name is set only on create so user
# renames survive. Scenes/zones come pre-curated from the bridge.
class GoveesDiscoveryHandler
  PREFIX = "govees/"

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "govees/+/config" ]

  def matches?(topic)
    topic.start_with?(PREFIX) && topic.end_with?("/config")
  end

  def handle(topic, payload)
    key  = topic.split("/")[1]
    data = JSON.parse(payload)
    light = Light.find_or_initialize_by(key: key)
    name = data["name"].to_s
    light.name = name.presence || key if light.new_record?
    light.sku = data["sku"] if data["sku"].present?
    light.supports_color      = !!data["supports_color"]
    light.supports_color_temp = !!data["supports_color_temp"]
    light.zones           = Array(data["zones"]).map(&:to_s)
    light.firmware_scenes = Array(data["scenes"]).map(&:to_s)
    light.save!
  rescue JSON::ParserError => e
    @logger.warn("GoveesDiscoveryHandler: invalid JSON on #{topic}: #{e.message}")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees_discovery_handler_test.rb`
Expected: PASS (4 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees_discovery_handler.rb test/govees_discovery_handler_test.rb
git commit -m "feat(govees): discovery handler for govees/<id>/config"
```

---

## Task 10: `GoveesStatusHandler` — consume `govees/<id>/state`

Replaces `govee_status_handler.rb` + `govee_zone_state_handler.rb`. Native units (no Mired). Includes zone bits.

**Files:**
- Create: `lib/govees_status_handler.rb`
- Test: `test/govees_status_handler_test.rb`

**Interfaces:**
- Produces: `GoveesStatusHandler.new(logger:)` with `#subscriptions = ["govees/+/state"]`, `#matches?`, `#handle`. Writes `LightState.record_state` (native brightness/kelvin/rgb, never clobbers absent fields) + `record_zone_state` per zone bit, and broadcasts on `"dashboard"` + the per-light turbo `light_power` partial (preserving the existing broadcast shape from `GoveeStatusHandler`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees_status_handler_test.rb
require "test_helper"
require "govees_status_handler"

class GoveesStatusHandlerTest < ActiveSupport::TestCase
  setup do
    LightState.delete_all; Light.delete_all
    @handler = GoveesStatusHandler.new(logger: Logger.new(IO::NULL))
  end

  def topic(k) = "govees/#{k}/state"

  test "subscriptions and matches target govees state topics" do
    assert_equal [ "govees/+/state" ], @handler.subscriptions
    assert @handler.matches?("govees/K/state")
    refute @handler.matches?("govees/K/config")
  end

  test "records native brightness, kelvin and rgb without conversion" do
    @handler.handle(topic("K"), JSON.generate("on" => true, "brightness" => 60,
      "color" => { "r" => 1, "g" => 2, "b" => 3 }, "reachable" => true))
    s = LightState.find_by(light_key: "K")
    assert_equal true, s.on
    assert_equal 60, s.brightness
    assert_equal 3, s.color_b
  end

  test "color_temp_k is stored verbatim (no mired math)" do
    @handler.handle(topic("K"), JSON.generate("on" => true, "color_temp_k" => 3000, "reachable" => true))
    assert_equal 3000, LightState.find_by(light_key: "K").color_temp_k
  end

  test "zone_states bits are recorded" do
    @handler.handle(topic("K"), JSON.generate("on" => true, "reachable" => true,
      "zone_states" => { "rippleLightToggle" => true, "sideLightToggle" => false }))
    s = LightState.find_by(light_key: "K")
    assert_equal true,  s.zone_states["rippleLightToggle"]
    assert_equal false, s.zone_states["sideLightToggle"]
  end

  test "broadcasts on the dashboard stream" do
    broadcasts = []
    server = ActionCable.server
    orig = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |s, d| broadcasts << [ s, d ] }
    @handler.handle(topic("K"), JSON.generate("on" => true, "brightness" => 55, "reachable" => true))
    assert_equal "dashboard", broadcasts.first[0]
    assert_equal 55, broadcasts.first[1][:lights].first[:brightness]
  ensure
    server.define_singleton_method(:broadcast, orig)
  end

  test "ignores invalid JSON" do
    assert_nothing_raised { @handler.handle(topic("K"), "x{") }
    assert_equal 0, LightState.count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees_status_handler_test.rb`
Expected: FAIL with `cannot load such file -- govees_status_handler`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees_status_handler.rb
require "json"

# Consumes the govees bridge state (govees/<key>/state). Native units: brightness
# 0-100, color_temp_k in Kelvin, color rgb. Absent fields are left untouched so a
# colour-temp-only update never clobbers the last RGB. Zone bits land in
# LightState#zone_states. Broadcasts mirror the previous GoveeStatusHandler.
class GoveesStatusHandler
  PREFIX = "govees/"
  BROADCAST_FIELDS = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  def initialize(logger:)
    @logger = logger
  end

  def subscriptions = [ "govees/+/state" ]

  def matches?(topic)
    topic.start_with?(PREFIX) && topic.end_with?("/state")
  end

  def handle(topic, payload)
    key   = topic.split("/")[1]
    data  = JSON.parse(payload)
    attrs = parse_state(data).merge(last_seen_at: Time.current)
    LightState.record_state(key, attrs)
    Array(data["zone_states"]).to_h.each { |inst, on| LightState.record_zone_state(key, inst, !!on) } if data["zone_states"].is_a?(Hash)
    broadcast(key, attrs, data["zone_states"])
    broadcast_turbo(key)
  rescue JSON::ParserError => e
    @logger.warn("GoveesStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def parse_state(data)
    attrs = { on: !!data["on"], reachable: data.key?("reachable") ? !!data["reachable"] : true }
    attrs[:brightness] = data["brightness"] if data.key?("brightness")
    if (c = data["color"])
      attrs[:color_r] = c["r"]; attrs[:color_g] = c["g"]; attrs[:color_b] = c["b"]
    end
    attrs[:color_temp_k] = data["color_temp_k"] if data["color_temp_k"]
    attrs
  end

  def broadcast(key, attrs, zone_states)
    payload = attrs.slice(*BROADCAST_FIELDS).merge(light_key: key)
    payload[:zones] = zone_states if zone_states.is_a?(Hash)
    ActionCable.server.broadcast("dashboard", { lights: [ payload ] })
  rescue => e
    @logger.warn("GoveesStatusHandler: broadcast failed: #{e.message}")
  end

  def broadcast_turbo(key)
    light = Light.find_by(key: key)
    return unless light
    row = LightRow.new(light: light, state: LightState.find_by(light_key: key))
    Turbo::StreamsChannel.broadcast_replace_to("light_#{key}",
      target: "light_power", partial: "lights/power", locals: { light: light, row: row })
  rescue => e
    @logger.warn("GoveesStatusHandler: turbo broadcast failed: #{e.message}")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/govees_status_handler_test.rb`
Expected: PASS (6 runs, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/govees_status_handler.rb test/govees_status_handler_test.rb
git commit -m "feat(govees): status handler for govees/<id>/state (native units + zones)"
```

---

## Task 11: `GoveesCommander` + controller switch to `set` verbs

**Files:**
- Create: `lib/govees_commander.rb`
- Modify: `app/controllers/light_switches_controller.rb`
- Test: `test/govees_commander_test.rb`, update `test/controllers/light_switches_controller_test.rb`

**Interfaces:**
- Produces: `GoveesCommander.publish(light, verb, mqtt_config:, mqtt_factory: nil)` — publishes `JSON.generate(verb)` to `govees/<key>/set` over a short-lived MQTT connection; raises `GoveesCommander::Error` on failure. Thin convenience wrappers: `.turn(light, on:, ...)`, `.set_brightness`, `.set_color`, `.set_color_temp`, `.set_zone(light, zone:, on:, ...)`, `.set_scene(light, scene:, ...)`.
- Controller maps params → verbs. Eviction/`max_active_zones` logic and immediate `LightState.record_*` + turbo responses stay exactly as today; only the publish target changes.

- [ ] **Step 1: Write the failing test**

```ruby
# test/govees_commander_test.rb
require "test_helper"
require "govees_commander"

class GoveesCommanderTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :published
    def initialize = @published = []
    def connect = self
    def publish(topic, payload) = @published << [ topic, payload ]
    def disconnect = nil
  end

  def light = Light.new(key: "K1", name: "L", zones: [])
  def cfg   = Struct.new(:host, :port).new("h", 1883)

  test "publishes a brightness verb to govees/<key>/set" do
    client = FakeClient.new
    GoveesCommander.set_brightness(light, value: 40, mqtt_config: cfg, mqtt_factory: -> { client })
    topic, payload = client.published.first
    assert_equal "govees/K1/set", topic
    assert_equal({ "brightness" => 40 }, JSON.parse(payload))
  end

  test "set_zone publishes a zone verb" do
    client = FakeClient.new
    GoveesCommander.set_zone(light, zone: "rippleLightToggle", on: true, mqtt_config: cfg, mqtt_factory: -> { client })
    assert_equal({ "zone" => { "name" => "rippleLightToggle", "on" => true } }, JSON.parse(client.published.first[1]))
  end

  test "raises Error when publish fails" do
    failing = Object.new.tap { |c| c.define_singleton_method(:connect) { raise "no broker" } }
    assert_raises(GoveesCommander::Error) do
      GoveesCommander.turn(light, on: true, mqtt_config: cfg, mqtt_factory: -> { failing })
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/govees_commander_test.rb`
Expected: FAIL with `cannot load such file -- govees_commander`

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/govees_commander.rb
require "mqtt"
require "json"

# Web-side choke point for govees commands: publishes a single `set` verb to
# govees/<key>/set over a short-lived MQTT connection. The bridge does the rest
# (routing, optimistic state, reconcile).
class GoveesCommander
  class Error < StandardError; end

  SET_TOPIC = "govees/%s/set".freeze

  def self.turn(light, on:, **kw)            = publish(light, { "power" => (on ? "on" : "off") }, **kw)
  def self.set_brightness(light, value:, **kw) = publish(light, { "brightness" => value.to_i }, **kw)
  def self.set_color(light, r:, g:, b:, **kw)  = publish(light, { "color" => { "r" => r.to_i, "g" => g.to_i, "b" => b.to_i } }, **kw)
  def self.set_color_temp(light, kelvin:, **kw) = publish(light, { "color_temp_k" => kelvin.to_i }, **kw)
  def self.set_zone(light, zone:, on:, **kw)   = publish(light, { "zone" => { "name" => zone, "on" => on } }, **kw)
  def self.set_scene(light, scene:, **kw)      = publish(light, { "scene" => scene.to_s }, **kw)

  def self.publish(light, verb, mqtt_config:, mqtt_factory: nil)
    factory = mqtt_factory || -> { MQTT::Client.new(host: mqtt_config.host, port: mqtt_config.port) }
    client  = factory.call
    begin
      client.connect
      client.publish(format(SET_TOPIC, light.key), JSON.generate(verb))
    rescue StandardError => e
      raise Error, "MQTT publish for '#{light.key}' failed: #{e.class}: #{e.message}"
    ensure
      begin; client.disconnect; rescue StandardError; nil; end
    end
  end
end
```

Now update `app/controllers/light_switches_controller.rb`: replace `require "govee_commander"` with `require "govees_commander"`, and swap every `GoveeCommander.` call for `GoveesCommander.` with the new signatures. The `turn` branch: zone lamps still use `set_zone(..., zone: "powerSwitch", on:)`; whole lamps `turn(on:)`. The `effect` branch becomes `scene`:

```ruby
    when "effect", "scene"
      GoveesCommander.set_scene(light, scene: params[:effect] || params[:scene], **opts)
```

And `rescue GoveeCommander::Error` → `rescue GoveesCommander::Error`. Leave all `LightState.record_*`, eviction, and `respond_*` code unchanged.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/govees_commander_test.rb test/controllers/light_switches_controller_test.rb`
Expected: PASS (update controller-test stubs/expectations from `GoveeCommander` to `GoveesCommander` and from `gv2mqtt` topics to `govees` verbs as needed)

- [ ] **Step 5: Commit**

```bash
git add lib/govees_commander.rb app/controllers/light_switches_controller.rb test/govees_commander_test.rb test/controllers/light_switches_controller_test.rb
git commit -m "feat(govees): commander + controller publish set verbs to govees/<id>/set"
```

---

## Task 12: Wire the bridge into the collector; drop old handlers

**Files:**
- Modify: `bin/ziwoas_collector`
- Test: `test/bin/ziwoas_collector_smoke_test.rb` (new, light smoke) — or extend existing collector test if present.

**Interfaces:**
- Consumes: `Govees::Bridge`, `GoveesStatusHandler`, `GoveesDiscoveryHandler`, `config.govee`.
- Behavior: register the two new handlers in the `MqttRouter` handler list (replacing the four `Govee*Handler`s); when `config.govee` is present, build a `Govees::PlatformApi` + `Govees::Bridge` and run it on its own supervised thread (added to `stoppables`/`threads`), guarded so the collector still boots when `config.govee` is nil.

- [ ] **Step 1: Write the failing test**

```ruby
# test/bin/ziwoas_collector_smoke_test.rb
require "test_helper"

class ZiwoasCollectorSmokeTest < ActiveSupport::TestCase
  test "collector file requires the govees handlers and bridge, not the old govee ones" do
    src = File.read(Rails.root.join("bin/ziwoas_collector"))
    assert_includes src, %(require "govees_status_handler")
    assert_includes src, %(require "govees_discovery_handler")
    assert_includes src, %(require "govees/bridge")
    refute_includes src, %(require "govee_status_handler")
    refute_includes src, %(require "govee_zone_state_handler")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/bin/ziwoas_collector_smoke_test.rb`
Expected: FAIL (old requires still present)

- [ ] **Step 3: Write minimal implementation**

Edit `bin/ziwoas_collector`:
- Replace the four `require "govee_*"` lines with `require "govees_status_handler"`, `require "govees_discovery_handler"`, `require "govees/bridge"`, `require "govees/platform_api"`.
- Replace the four handler registrations with:

```ruby
handlers << GoveesStatusHandler.new(logger: logger)
handlers << GoveesDiscoveryHandler.new(logger: logger)
```

- After the router thread block, add:

```ruby
if config.govee
  api = Govees::PlatformApi.new(api_key: config.govee.api_key)
  bridge = Govees::Bridge.new(mqtt_config: config.mqtt, govee_config: config.govee, api: api, logger: logger)
  stoppables << bridge
  threads << Thread.new { Thread.current.name = "govees_bridge"; bridge.run }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/bin/ziwoas_collector_smoke_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add bin/ziwoas_collector test/bin/ziwoas_collector_smoke_test.rb
git commit -m "feat(govees): run the bridge in the collector, swap to govees handlers"
```

---

## Task 13: Remove govee2mqtt + old handler files

**Files:**
- Delete: `lib/govee_status_handler.rb`, `lib/govee_discovery_handler.rb`, `lib/govee_zone_discovery_handler.rb`, `lib/govee_zone_state_handler.rb`, `lib/govee_commander.rb` and their tests (`test/govee_status_handler_test.rb`, `test/govee_discovery_handler_test.rb`, `test/govee_zone_discovery_handler_test.rb`, `test/govee_commander_test.rb`).
- Delete: `config/govee2mqtt.env`, `config/govee2mqtt.env.example`, `docs/govee2mqtt-setup.md`, `vendor/govee2mqtt/` (gitignored — just ensure not referenced).
- Modify: `docker-compose.yml`, `docker-compose.dev.yml` (remove the `govee2mqtt` service), `Procfile.dev` (remove the `govee` process line), `Brewfile` (remove `brew "rust"` if only there for govee2mqtt).

- [ ] **Step 1: Find every remaining reference**

Run: `git grep -n -iE "gv2mqtt|govee2mqtt|GoveeCommander|GoveeStatusHandler|GoveeDiscoveryHandler|GoveeZone" -- . ':!docs/superpowers'`
Expected: only hits in files this task deletes/edits. Fix any stragglers.

- [ ] **Step 2: Delete files and edit configs**

```bash
git rm lib/govee_status_handler.rb lib/govee_discovery_handler.rb lib/govee_zone_discovery_handler.rb lib/govee_zone_state_handler.rb lib/govee_commander.rb
git rm test/govee_status_handler_test.rb test/govee_discovery_handler_test.rb test/govee_zone_discovery_handler_test.rb test/govee_commander_test.rb
git rm config/govee2mqtt.env.example docs/govee2mqtt-setup.md
```

Edit `docker-compose.yml`, `docker-compose.dev.yml`, `Procfile.dev`, `Brewfile` to drop the govee2mqtt service / process / rust line. Remove `config/govee2mqtt.env` locally (it is gitignored).

- [ ] **Step 3: Run the full suite**

Run: `bin/rails test`
Expected: PASS, 0 failures (suite count drops by the deleted tests, rises by the new govees tests).

- [ ] **Step 4: RuboCop + Brakeman**

Run: `bin/rubocop && bin/brakeman -q --no-pager`
Expected: no offenses, 0 warnings. Fix any.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(govees): remove govee2mqtt and the old gv2mqtt handlers"
```

---

## Task 14: Full CI + manual smoke verification

**Files:** none (verification only).

- [ ] **Step 1: Stop the dev stack** (a running collector locks SQLite and fails CI DB steps)

Run: `pkill -f ziwoas_collector; pkill -f "bin/dev"` (or stop your foreman session)

- [ ] **Step 2: Run the full CI**

Run: `bin/ci`
Expected: all green — tests/0, RuboCop, audits, Brakeman 0 warnings, seeds.

- [ ] **Step 3: Manual end-to-end smoke** (real lamps, real broker)

Start the stack: `bin/dev -m all=1`. Then verify, watching a real lamp:
- UI power on/off + brightness + colour reflect within ~1–2 s (LAN read-back).
- `mosquitto_sub -h <broker> -t 'govees/#' -v` shows `govees/<id>/config` (retained) and `govees/<id>/state` updating.
- Toggle a zone on the Uplighter (H60B0) in the UI → API control fires; within the API poll window the zone bit reconciles.
- Change a lamp on the Govee app/remote → within the LAN poll (~8 s) the change appears in the UI (off adopts immediately; on+change clarifies via API).

- [ ] **Step 4: Resolve the implementation open points from the spec**

- Confirm H60B0 zone values are real telemetry (toggle externally, observe reconcile).
- Confirm LAN `devStatus` field names against a live reply (`color` vs `colorTemInKelvin`, brightness 0–100); adjust `LanClient.parse_status` if Govee differs.

- [ ] **Step 5: Commit any fixes from smoke, then finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to decide merge/PR.

---

## Self-Review

**Spec coverage:**
- LAN client → Task 1. Platform API → Task 2. Registry/curation (segments/zones/scenes) → Task 3. State store/conflict logic → Task 4. Command routing table → Task 5. Reconciler (LAN/API/clarify) → Task 6. Bridge/threads/contract publish → Task 7. Config (`govee:`, intervals, names, ENV key) → Task 8. Clean MQTT contract consumers → Tasks 9–10. Commander + controller → Task 11. Collector wiring → Task 12. Migration/removal → Task 13. CI + smoke + spec open-points → Task 14. All spec sections map to a task.
- Quirks: segments dropped (T3 registry), zones curated via `ZONE_META.keys` (T3), scenes from API list (T3), native Kelvin/brightness (T5/T6/T10), power-as-one-concept (T5 router), color_mode implicit (T10 non-clobber), DreamViewScenic power_only (T3). Covered.
- Error handling: API body-code/5xx → Error (T2); registry/reconciler rescue + log (T3/T6); bridge thread supervision + stop! (T7); commander Error → controller `:service_unavailable` (T11). Covered.

**Placeholder scan:** No TBD/TODO; every code step shows complete code. Task 5 includes an explicit verify-then-adjust sub-step (zone-bit merge) with the test and the fix — concrete, not a placeholder.

**Type consistency:** `Device` struct fields are used identically across T3/T5/T6/T7. `StateStore#apply_telemetry` returns `{published:, changed:, needs_api_clarification:}` consumed by T6/T7. Telemetry hashes use symbol keys (`:on, :brightness, :color, :color_temp_k, :reachable, :zone_states`) consistently in T4/T6. Contract JSON uses string keys consistently in T7/T9/T10. `scene_index` value shape `{id:, param_id:}` set in T3, read in T5.
