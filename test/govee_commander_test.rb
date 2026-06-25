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
    GoveeCommander.refresh(@light, **opts(c))
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
