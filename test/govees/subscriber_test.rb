# test/govees/subscriber_test.rb
require "test_helper"
require "govees/subscriber"

class GoveesSubscriberConfigTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
    Room.delete_all
    @sub = Govees::Subscriber.new(logger: Logger.new(IO::NULL))
  end

  test "subscribes to and matches govees config topics" do
    assert_includes @sub.subscriptions, "govees/+/config"
    assert @sub.matches?("govees/14ABDB4844064B60/config")
  end

  test "config upserts a Light with sku, capabilities, scenes and zones" do
    @sub.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Uplighter", "supports_color" => true,
      "supports_color_temp" => true, "zones" => [ "rippleLightToggle" ], "scenes" => [ "Sunset" ]))
    l = Light.find_by(key: "K1")
    assert_equal "H60B0", l.sku
    assert_equal "Uplighter", l.name
    assert l.supports_color
    assert_equal [ "rippleLightToggle" ], l.zones
    assert_equal [ "Sunset" ], l.firmware_scenes
  end

  test "user rename is preserved on later config" do
    Light.create!(key: "K1", name: "Mein Name", zones: [])
    @sub.handle("govees/K1/config", JSON.generate("sku" => "H60B0", "name" => "Uplighter", "zones" => [], "scenes" => []))
    assert_equal "Mein Name", Light.find_by(key: "K1").name
  end

  test "config ignores invalid JSON" do
    assert_nothing_raised { @sub.handle("govees/K1/config", "x{") }
    assert_equal 0, Light.count
  end

  test "config with room assigns the Light to a Room (creating it if needed)" do
    @sub.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Uplighter", "room" => "Wohnzimmer",
      "supports_color" => true, "supports_color_temp" => true, "zones" => [], "scenes" => []))
    l = Light.find_by!(key: "K1")
    assert_not_nil l.room
    assert_equal "Wohnzimmer", l.room.name
  end

  test "config with room reuses existing Room record" do
    existing = Room.create!(name: "Schlafzimmer")
    @sub.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Lamp", "room" => "Schlafzimmer",
      "supports_color" => false, "supports_color_temp" => false, "zones" => [], "scenes" => []))
    assert_equal existing.id, Light.find_by!(key: "K1").room_id
    assert_equal 1, Room.count
  end

  test "config without room leaves room nil" do
    @sub.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Lamp",
      "supports_color" => false, "supports_color_temp" => false, "zones" => [], "scenes" => []))
    assert_nil Light.find_by!(key: "K1").room
  end
end

class GoveesSubscriberStateTest < ActiveSupport::TestCase
  setup do
    LightState.delete_all; Light.delete_all
    @sub = Govees::Subscriber.new(logger: Logger.new(IO::NULL))
  end

  def topic(k) = "govees/#{k}/state"

  test "subscriptions and matches now include state topics" do
    assert_equal [ "govees/+/config", "govees/+/state" ], @sub.subscriptions
    assert @sub.matches?("govees/K/state")
    assert @sub.matches?("govees/K/config")
  end

  test "records native brightness, kelvin and rgb without conversion" do
    @sub.handle(topic("K"), JSON.generate("on" => true, "brightness" => 60,
      "color" => { "r" => 1, "g" => 2, "b" => 3 }, "reachable" => true))
    s = LightState.find_by(light_key: "K")
    assert_equal true, s.on
    assert_equal 60, s.brightness
    assert_equal 3, s.color_b
  end

  test "color_temp_k is stored verbatim (no mired math)" do
    @sub.handle(topic("K"), JSON.generate("on" => true, "color_temp_k" => 3000, "reachable" => true))
    assert_equal 3000, LightState.find_by(light_key: "K").color_temp_k
  end

  test "zone_states bits are recorded" do
    @sub.handle(topic("K"), JSON.generate("on" => true, "reachable" => true,
      "zone_states" => { "rippleLightToggle" => true, "sideLightToggle" => false }))
    s = LightState.find_by(light_key: "K")
    assert_equal true,  s.zone_states["rippleLightToggle"]
    assert_equal false, s.zone_states["sideLightToggle"]
  end

  test "broadcasts on the dashboard stream" do
    broadcasts = []
    server = ActionCable.server
    orig = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |s, d| broadcasts << [ s, d ] }
    @sub.handle(topic("K"), JSON.generate("on" => true, "brightness" => 55, "reachable" => true))
    assert_equal "dashboard", broadcasts.first[0]
    assert_equal 55, broadcasts.first[1][:lights].first[:brightness]
  ensure
    server.define_singleton_method(:broadcast, orig)
  end

  test "state ignores invalid JSON" do
    assert_nothing_raised { @sub.handle(topic("K"), "x{") }
    assert_equal 0, LightState.count
  end
end
