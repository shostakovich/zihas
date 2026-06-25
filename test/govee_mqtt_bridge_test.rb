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
    @clock = 0.0
    @bridge = GoveeMqttBridge.new(
      mqtt_config: @mqtt_config, govee_config: @govee_config,
      logger: Logger.new(StringIO.new), lan_client: @lan,
      lights_provider: -> { Light.all.to_a }, mqtt_factory: -> { @mqtt },
      clock: -> { @clock }
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

  # FIX 2: reachability timeout tests
  test "poll_once publishes reachable:false with last state when lamp goes stale" do
    datagram = JSON.generate("msg" => { "cmd" => "devStatus", "data" => {
      "onOff" => 1, "brightness" => 77, "color" => { "r" => 0, "g" => 0, "b" => 0 },
      "colorTemInKelvin" => 2700
    } })
    @clock = 0.0
    @bridge.handle_datagram(datagram, "192.168.10.20")
    @mqtt.published.clear

    # Advance clock beyond 2 * poll_interval_seconds (60)
    @clock = 61.0
    @bridge.poll_once

    offline = @mqtt.published.find { |t, _| t == "govee/stehlampe/status" }
    assert offline, "Expected an offline status publish"
    body = JSON.parse(offline[1])
    assert_equal false, body["reachable"]
    assert_equal 77,    body["brightness"]
    assert_equal true,  body["on"]
  end

  test "poll_once does NOT mark a freshly-seen lamp unreachable" do
    datagram = JSON.generate("msg" => { "cmd" => "devStatus", "data" => {
      "onOff" => 1, "brightness" => 50, "color" => { "r" => 0, "g" => 0, "b" => 0 },
      "colorTemInKelvin" => 0
    } })
    @clock = 0.0
    @bridge.handle_datagram(datagram, "192.168.10.20")
    @mqtt.published.clear

    # Only 10 seconds passed — well within 2 * 30 = 60 window
    @clock = 10.0
    @bridge.poll_once

    offline = @mqtt.published.select { |t, b| t == "govee/stehlampe/status" && JSON.parse(b)["reachable"] == false }
    assert_equal [], offline
  end

  test "poll_once does NOT mark never-seen lamps unreachable" do
    @bridge.poll_once
    offline = @mqtt.published.select { |t, b| t == "govee/stehlampe/status" && JSON.parse(b)["reachable"] == false }
    assert_equal [], offline
  end

  # FIX 4: dispatch test gaps
  test "handle_command unknown command makes no LAN calls and does not raise" do
    assert_nothing_raised { @bridge.handle_command("govee/stehlampe/command/bogus", "{}") }
    assert_equal [], @lan.calls
  end

  test "handle_command color_temp sends color_temp and requests status" do
    @bridge.handle_command("govee/stehlampe/command/color_temp", JSON.generate("temp_k" => 3000))
    assert_equal [ :color_temp, "192.168.10.20", 3000 ], @lan.calls[0]
    assert_equal [ :request_status, "192.168.10.20" ],   @lan.calls[1]
  end
end
