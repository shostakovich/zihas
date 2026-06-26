require "test_helper"
require "govee_scene_discovery_handler"
require "logger"
require "stringio"

class GoveeSceneDiscoveryHandlerTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    @log_io  = StringIO.new
    @handler = GoveeSceneDiscoveryHandler.new(logger: Logger.new(@log_io))
    @light   = Light.create!(name: "Decke", key: "14ABDB4844064B60")
  end

  def scene_config(overrides = {})
    JSON.generate({
      "name"          => "Mode/Scene",
      "unique_id"     => "gv2mqtt-14ABDB4844064B60-mode-scene",
      "command_topic" => "gv2mqtt/14ABDB4844064B60/set-mode-scene",
      "state_topic"   => "gv2mqtt/14ABDB4844064B60/notify-mode-scene",
      "options"       => [ "Forest", "Aurora", "Candy" ]
    }.merge(overrides))
  end

  test "subscriptions targets the select config topic" do
    assert_equal [ "gv2mqtt/select/+/config" ], @handler.subscriptions
  end

  test "matches select config topics only" do
    assert @handler.matches?("gv2mqtt/select/gv2mqtt-14ABDB4844064B60-mode-scene/config")
    refute @handler.matches?("gv2mqtt/light/14ABDB4844064B60/config")
    refute @handler.matches?("gv2mqtt/select/x/state")
  end

  test "stores the scene options on the matching light" do
    @handler.handle("gv2mqtt/select/gv2mqtt-14ABDB4844064B60-mode-scene/config", scene_config)
    assert_equal %w[Forest Aurora Candy], @light.reload.firmware_scenes
  end

  test "ignores a non-scene select (e.g. work mode)" do
    cfg = scene_config("unique_id" => "gv2mqtt-14ABDB4844064B60-workMode",
                       "command_topic" => "gv2mqtt/14ABDB4844064B60/set-work-mode",
                       "options" => [ "Low", "High" ])
    @handler.handle("gv2mqtt/select/gv2mqtt-14ABDB4844064B60-workMode/config", cfg)
    assert_equal [], @light.reload.firmware_scenes
  end

  test "ignores a config for an unknown light" do
    cfg = scene_config("command_topic" => "gv2mqtt/FFFFFFFFFFFFFFFF/set-mode-scene",
                       "unique_id" => "gv2mqtt-FFFFFFFFFFFFFFFF-mode-scene")
    assert_nothing_raised { @handler.handle("gv2mqtt/select/x/config", cfg) }
    assert_equal [], @light.reload.firmware_scenes
    assert_match(/no light/i, @log_io.string)
  end

  test "ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("gv2mqtt/select/x/config", "not-json{") }
    assert_match(/invalid json/i, @log_io.string)
  end
end
