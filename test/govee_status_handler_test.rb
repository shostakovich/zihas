# test/govee_status_handler_test.rb
require "test_helper"
require "govee_status_handler"
require "logger"
require "stringio"

class GoveeStatusHandlerTest < ActiveSupport::TestCase
  setup do
    LightState.delete_all
    Light.delete_all
    @log_io  = StringIO.new
    @handler = GoveeStatusHandler.new(logger: Logger.new(@log_io))
  end

  def state_topic(key) = "gv2mqtt/light/#{key}/state"

  def capture_broadcasts
    broadcasts = []
    server   = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, data| broadcasts << [ stream, data ] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "subscriptions cover state and availability" do
    assert_equal [ "gv2mqtt/light/+/state", "gv2mqtt/availability" ], @handler.subscriptions
  end

  test "matches state topics and the availability topic only" do
    assert @handler.matches?("gv2mqtt/light/14ABDB4844064B60/state")
    assert @handler.matches?("gv2mqtt/availability")
    refute @handler.matches?("gv2mqtt/light/gv2mqtt-14ABDB4844064B60/config")
    refute @handler.matches?("shellies/bkw/status/switch:0")
  end

  test "handle records on/brightness/color from rgb-mode state" do
    @handler.handle(state_topic("14ABDB4844064B60"),
      JSON.generate({ "state" => "ON", "brightness" => 60, "color_mode" => "rgb",
                      "color" => { "r" => 10, "g" => 20, "b" => 30 } }))
    s = LightState.find_by(light_key: "14ABDB4844064B60")
    assert_equal true, s.on
    assert_equal 60,   s.brightness
    assert_equal 30,   s.color_b
    assert_equal true, s.reachable
  end

  test "handle converts color_temp mireds to kelvin" do
    @handler.handle(state_topic("ABC123"),
      JSON.generate({ "state" => "ON", "brightness" => 80, "color_mode" => "color_temp",
                      "color_temp" => 250 }))
    s = LightState.find_by(light_key: "ABC123")
    # 1_000_000 / 250 = 4000
    assert_equal 4000, s.color_temp_k
  end

  test "handle does not clobber color when a color_temp-only update arrives" do
    @handler.handle(state_topic("ABC123"),
      JSON.generate({ "state" => "ON", "color" => { "r" => 1, "g" => 2, "b" => 3 } }))
    @handler.handle(state_topic("ABC123"),
      JSON.generate({ "state" => "ON", "color_temp" => 500 }))
    s = LightState.find_by(light_key: "ABC123")
    assert_equal 1,    s.color_r, "previous rgb must be preserved"
    assert_equal 2000, s.color_temp_k
  end

  test "handle marks the light off on state OFF" do
    @handler.handle(state_topic("ABC123"), JSON.generate({ "state" => "OFF" }))
    assert_equal false, LightState.find_by(light_key: "ABC123").on
  end

  test "handle broadcasts the light state on the dashboard stream" do
    capture_broadcasts do |broadcasts|
      @handler.handle(state_topic("ABC123"), JSON.generate({ "state" => "ON", "brightness" => 55 }))
      stream, data = broadcasts.first
      assert_equal "dashboard", stream
      assert_equal "ABC123", data[:lights].first[:light_key]
      assert_equal 55,       data[:lights].first[:brightness]
    end
  end

  test "availability offline marks all known lights unreachable" do
    LightState.record_state("ABC123", on: true, reachable: true)
    @handler.handle("gv2mqtt/availability", "offline")
    assert_equal false, LightState.find_by(light_key: "ABC123").reachable
  end

  test "availability online is a no-op" do
    LightState.record_state("ABC123", on: true, reachable: true)
    @handler.handle("gv2mqtt/availability", "online")
    assert_equal true, LightState.find_by(light_key: "ABC123").reachable
  end

  test "handle ignores invalid JSON" do
    assert_nothing_raised { @handler.handle(state_topic("ABC123"), "not-json{") }
    assert_equal 0, LightState.count
    assert_match(/invalid json/i, @log_io.string)
  end

  test "broadcasts a turbo stream replacing the power partial for the light" do
    Light.create!(name: "Lampe", key: "BCAST1", zones: [])
    handler = GoveeStatusHandler.new(logger: Logger.new(IO::NULL))
    streams = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(stream, **kw) { streams << [ stream, kw[:target] ] }) do
      handler.handle("gv2mqtt/light/BCAST1/state", %({"state":"ON","brightness":50}))
    end
    assert_includes streams, [ "light_BCAST1", "light_power" ]
  end
end
