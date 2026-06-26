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
