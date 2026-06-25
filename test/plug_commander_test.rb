require "test_helper"
require "config_loader"
require "plug_commander"

class PlugCommanderTest < ActiveSupport::TestCase
  class FakeMqtt
    attr_reader :published, :disconnected

    def initialize(fail_connect: false)
      @fail_connect = fail_connect
      @published    = []
      @disconnected = false
    end

    def connect
      raise Errno::ECONNREFUSED, "broker down" if @fail_connect
    end

    def publish(topic, payload) = @published << [ topic, payload ]
    def disconnect = @disconnected = true
  end

  setup do
    SwitchCommand.delete_all
    @mqtt_config = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @plug = ConfigLoader::PlugCfg.new(id: "lamp", name: "Lampe", role: :consumer,
                                      driver: :shelly, ain: nil, switchable: true)
  end

  def commander(client)
    PlugCommander.new(mqtt_config: @mqtt_config, mqtt_factory: -> { client })
  end

  test "publishes on to the shelly command topic and logs the command" do
    client = FakeMqtt.new
    commander(client).switch(@plug, :on, source: :manual)
    assert_equal [ [ "shellies/lamp/command/switch:0", "on" ] ], client.published
    assert client.disconnected
    cmd = SwitchCommand.last
    assert_equal %w[lamp on manual], [ cmd.plug_id, cmd.action, cmd.source ]
  end

  test "publishes off with source schedule" do
    client = FakeMqtt.new
    commander(client).switch(@plug, :off, source: :schedule)
    assert_equal [ [ "shellies/lamp/command/switch:0", "off" ] ], client.published
    assert_equal %w[off schedule], [ SwitchCommand.last.action, SwitchCommand.last.source ]
  end

  test "failed publish raises and writes no log row" do
    client = FakeMqtt.new(fail_connect: true)
    assert_raises(PlugCommander::Error) { commander(client).switch(@plug, :on, source: :manual) }
    assert_equal 0, SwitchCommand.count
  end

  test "unknown driver raises a clear error" do
    fritz = ConfigLoader::PlugCfg.new(id: "tv", name: "TV", role: :consumer,
                                      driver: :fritz_dect, ain: "1", switchable: true)
    e = assert_raises(PlugCommander::Error) { commander(FakeMqtt.new).switch(fritz, :on, source: :manual) }
    assert_match(/fritz_dect/, e.message)
    assert_equal 0, SwitchCommand.count
  end

  test "non-switchable plug raises" do
    plain = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer,
                                      driver: :shelly, ain: nil, switchable: false)
    assert_raises(PlugCommander::Error) { commander(FakeMqtt.new).switch(plain, :on, source: :manual) }
  end

  test "invalid action raises ArgumentError" do
    assert_raises(ArgumentError) { commander(FakeMqtt.new).switch(@plug, :toggle, source: :manual) }
  end
end
