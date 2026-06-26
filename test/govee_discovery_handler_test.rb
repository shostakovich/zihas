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
