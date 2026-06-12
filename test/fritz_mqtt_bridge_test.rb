require "test_helper"
require "fritz_mqtt_bridge"
require "fritz_dect_client"
require "config_loader"
require "logger"
require "stringio"

class FritzMqttBridgeTest < ActiveSupport::TestCase
  setup do
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)

    @plug = ConfigLoader::PlugCfg.new(
      id: "robbebike", name: "Waschmaschine",
      role: :consumer, driver: :fritz_dect, ain: "08761 0500475"
    )
    @mqtt_config = ConfigLoader::MqttCfg.new(
      host: "localhost", port: 1883, topic_prefix: "shellies"
    )
    @fritz_poll_cfg = ConfigLoader::FritzPollCfg.new(
      active_interval_seconds: 5,
      idle_interval_seconds:   60,
      idle_threshold_w:        10,
      timeout_seconds:         2,
    )
  end

  def fake_fritz_client(apower_w:, aenergy_wh:)
    client = Object.new
    client.define_singleton_method(:fetch) do |_plug|
      FritzDectClient::Reading.new(apower_w: apower_w, aenergy_wh: aenergy_wh)
    end
    client
  end

  def fake_mqtt_client
    published = []
    client = Object.new
    client.define_singleton_method(:connect) { }
    client.define_singleton_method(:disconnect) { }
    client.define_singleton_method(:publish) { |topic, payload| published << [ topic, payload ] }
    client.define_singleton_method(:published) { published }
    client
  end

  def build_bridge(fritz_client:, mqtt_client: nil)
    mqtt_client ||= fake_mqtt_client
    FritzMqttBridge.new(
      fritz_client:   fritz_client,
      plug:           @plug,
      mqtt_config:    @mqtt_config,
      fritz_poll_cfg: @fritz_poll_cfg,
      logger:         @logger,
      mqtt_factory:   -> { mqtt_client },
    )
  end

  test "poll_and_publish sends correct topic" do
    fritz = fake_fritz_client(apower_w: 42.5, aenergy_wh: 100.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 1, mqtt.published.length
    assert_equal "shellies/robbebike/status/switch:0", mqtt.published.first[0]
  end

  test "poll_and_publish sends correct JSON payload" do
    fritz = fake_fritz_client(apower_w: 42.5, aenergy_wh: 100.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    data = JSON.parse(mqtt.published.first[1])
    assert_in_delta 42.5,  data["apower"]
    assert_in_delta 100.0, data.dig("aenergy", "total")
  end

  test "interval is active when power above threshold" do
    fritz = fake_fritz_client(apower_w: 50.0, aenergy_wh: 1.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 5, bridge.interval
  end

  test "interval is idle when power at or below threshold" do
    fritz = fake_fritz_client(apower_w: 2.0, aenergy_wh: 1.0)
    mqtt  = fake_mqtt_client
    bridge = build_bridge(fritz_client: fritz, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 60, bridge.interval
  end

  test "interval starts as idle before first poll" do
    fritz = fake_fritz_client(apower_w: 0.0, aenergy_wh: 0.0)
    bridge = build_bridge(fritz_client: fritz)

    assert_equal 60, bridge.interval
  end

  test "poll_and_publish logs warning on fritz error and does not publish" do
    erroring = Object.new
    erroring.define_singleton_method(:fetch) { |_| raise FritzDectClient::Error, "timeout" }
    mqtt   = fake_mqtt_client
    bridge = build_bridge(fritz_client: erroring, mqtt_client: mqtt)

    bridge.poll_and_publish(mqtt)

    assert_equal 0, mqtt.published.length
    assert_match(/timeout/i, @log_io.string)
  end
end
