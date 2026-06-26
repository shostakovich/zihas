# test/govee_zone_state_handler_test.rb
require "test_helper"
require "govee_zone_state_handler"
require "logger"
require "stringio"

class GoveeZoneStateHandlerTest < ActiveSupport::TestCase
  setup do
    LightState.delete_all
    @handler = GoveeZoneStateHandler.new(logger: Logger.new(StringIO.new))
  end

  def capture_broadcasts
    broadcasts = []
    server   = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, data| broadcasts << [ stream, data ] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "subscribes to the per-zone switch state topic" do
    assert_equal [ "gv2mqtt/switch/+/+/state" ], @handler.subscriptions
  end

  test "matches a zone state topic but not a config topic" do
    assert @handler.matches?("gv2mqtt/switch/UP1/rippleLightToggle/state")
    refute @handler.matches?("gv2mqtt/switch/gv2mqtt-UP1-rippleLightToggle/config")
  end

  test "records a known zone toggle's ON state" do
    @handler.handle("gv2mqtt/switch/UP1/rippleLightToggle/state", "ON")
    assert_equal({ "rippleLightToggle" => true }, LightState.find_by(light_key: "UP1").zone_states)
  end

  test "ignores non-zone toggles (powerSwitch handled by the light state)" do
    @handler.handle("gv2mqtt/switch/UP1/powerSwitch/state", "ON")
    assert_nil LightState.find_by(light_key: "UP1")
  end

  test "broadcasts the changed zone bit on the dashboard stream" do
    capture_broadcasts do |broadcasts|
      @handler.handle("gv2mqtt/switch/UP1/sideLightToggle/state", "OFF")
      assert_equal "dashboard", broadcasts.first[0]
      assert_equal [ { light_key: "UP1", zones: { "sideLightToggle" => false } } ],
                   broadcasts.first[1][:lights]
    end
  end
end
