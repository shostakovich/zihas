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
