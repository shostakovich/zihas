# test/govees/bridge_test.rb
require "test_helper"
require "govees/bridge"
require "govees/device"

class GoveesBridgeTest < ActiveSupport::TestCase
  class FakePublisher
    attr_reader :published
    def initialize = @published = []
    def connect = self
    # Adjustment 2: retain is a positional arg, not keyword
    def publish(topic, payload, retain = false) = @published << { topic: topic, payload: payload, retain: retain }
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

  test "handle_datagram with a scan reply calls record_lan_ip on the registry" do
    recorded = []
    registry = Object.new
    registry.define_singleton_method(:record_lan_ip) { |mac, ip| recorded << { mac: mac, ip: ip } }
    registry.define_singleton_method(:all) { [] }
    registry.define_singleton_method(:find) { |_| nil }

    pub   = FakePublisher.new
    store = Govees::StateStore.new(clock: -> { 0.0 })
    router = Object.new
    router.define_singleton_method(:handle) { |_k, _v| nil }
    mqtt = Struct.new(:host, :port).new("h", 1883)
    cfg  = Struct.new(:lan_poll_seconds, :api_poll_seconds, :pending_window_seconds).new(5, 180, 5)
    bridge = Govees::Bridge.new(
      mqtt_config: mqtt, govee_config: cfg, api: nil, logger: Logger.new(IO::NULL),
      registry: registry, store: store, router: router, reconciler: nil,
      mqtt_factory: -> { pub }
    )

    scan_reply = JSON.generate("msg" => { "cmd" => "scan", "data" => {
      "ip" => "192.168.8.100", "device" => "14:AB:DB:48:44:06:4B:60", "sku" => "H60B0" } })
    bridge.send(:handle_datagram, scan_reply, "192.168.8.100")

    assert_equal 1, recorded.length
    assert_equal "14:AB:DB:48:44:06:4B:60", recorded.first[:mac]
    assert_equal "192.168.8.100", recorded.first[:ip]
  end

  test "publish_config includes room in the payload" do
    bridge = build
    d_with_room = Govees::Device.new(key: "K", api_id: "14:AB", sku: "H60B0", name: "Uplighter",
      ip: "1.2.3.4", room: "Wohnzimmer",
      supports_color: true, supports_color_temp: true, zones: [], scenes: [], scene_index: {}, power_only: false)
    bridge.publish_config(d_with_room)
    msg = @pub.published.find { |m| m[:topic] == "govees/K/config" }
    assert_equal "Wohnzimmer", JSON.parse(msg[:payload])["room"]
  end
end
