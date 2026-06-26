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
    @handler = GoveeStatusHandler.new(topic_prefix: "govee", logger: Logger.new(@log_io))
  end

  def payload(overrides = {})
    JSON.generate({ "on" => true, "brightness" => 60, "color_r" => 10, "color_g" => 20,
                    "color_b" => 30, "color_temp_k" => 0, "reachable" => true }.merge(overrides))
  end

  def capture_broadcasts
    broadcasts = []
    server = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, data| broadcasts << [ stream, data ] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "subscriptions targets govee status topics" do
    assert_equal [ "govee/+/status" ], @handler.subscriptions
  end

  test "matches only govee status topics" do
    assert @handler.matches?("govee/lamp/status")
    refute @handler.matches?("shellies/bkw/status/switch:0")
  end

  test "handle writes LightState from the payload" do
    @handler.handle("govee/lamp/status", payload)
    state = LightState.find_by(light_key: "lamp")
    assert_equal true, state.on
    assert_equal 60,   state.brightness
    assert_equal 30,   state.color_b
    assert_equal true, state.reachable
  end

  test "handle broadcasts the light state on the dashboard stream" do
    capture_broadcasts do |broadcasts|
      @handler.handle("govee/lamp/status", payload)
      stream, data = broadcasts.first
      assert_equal "dashboard", stream
      assert_equal "lamp", data[:lights].first[:light_key]
      assert_equal 60,     data[:lights].first[:brightness]
    end
  end

  test "handle fills the light sku when present" do
    Light.create!(name: "Lampe", key: "lamp")
    @handler.handle("govee/lamp/status", payload("sku" => "H6076"))
    assert_equal "H6076", Light.find_by(key: "lamp").sku
  end

  test "handle ignores invalid JSON" do
    assert_nothing_raised { @handler.handle("govee/lamp/status", "not-json{") }
    assert_equal 0, LightState.count
    assert_match(/invalid json/i, @log_io.string)
  end

  # FIX 2: last_seen_at not bumped when reachable:false
  test "handle does not update last_seen_at when reachable is false" do
    t0 = Time.current
    travel_to t0 do
      @handler.handle("govee/lamp/status", payload("reachable" => true))
    end
    state_after_t0 = LightState.find_by(light_key: "lamp")
    assert_in_delta t0.to_f, state_after_t0.last_seen_at.to_f, 1.0

    t1 = t0 + 60
    travel_to t1 do
      @handler.handle("govee/lamp/status", payload("reachable" => false))
    end
    state_after_t1 = LightState.find_by(light_key: "lamp")
    assert_in_delta t0.to_f, state_after_t1.last_seen_at.to_f, 1.0, "last_seen_at must not change on unreachable"
  end

  test "handle updates last_seen_at when reachable is true" do
    t0 = Time.current
    travel_to t0 do
      @handler.handle("govee/lamp/status", payload("reachable" => true))
    end
    t1 = t0 + 10
    travel_to t1 do
      @handler.handle("govee/lamp/status", payload("reachable" => true))
    end
    state = LightState.find_by(light_key: "lamp")
    assert_in_delta t1.to_f, state.last_seen_at.to_f, 1.0
  end
end
