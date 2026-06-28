# test/govees/subscriber_test.rb
require "test_helper"
require "govees/subscriber"
require "turbo/broadcastable/test_helper"

class GoveesSubscriberConfigTest < ActiveSupport::TestCase
  setup do
    Light.delete_all
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

  test "config survives an ActiveRecord error instead of propagating" do
    bad = Light.new(key: "K1")
    def bad.save! = raise(ActiveRecord::RecordInvalid.new(self))
    Light.stub :find_or_initialize_by, bad do
      assert_nothing_raised do
        @sub.handle("govees/K1/config", JSON.generate("sku" => "H60B0", "zones" => [], "scenes" => []))
      end
    end
  end

  test "config ignores the room field (rooms feature removed)" do
    @sub.handle("govees/K1/config", JSON.generate(
      "sku" => "H60B0", "name" => "Uplighter", "room" => "Wohnzimmer",
      "supports_color" => true, "supports_color_temp" => true, "zones" => [], "scenes" => []))
    l = Light.find_by!(key: "K1")
    assert_equal "Uplighter", l.name
    assert_not l.respond_to?(:room)
  end
end

class GoveesSubscriberStateTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

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

  test "reconciles the list card and the detail hero via Turbo Streams" do
    Light.create!(key: "K", name: "Lampe", zones: [])

    @sub.handle(topic("K"), JSON.generate("on" => true, "brightness" => 55, "reachable" => true))

    # capture_turbo_stream_broadcasts renders for real — this fails pre-fix because
    # the deleted partials lights/power and switches/light_card raise MissingTemplate
    # (caught by rescue, so broadcasts never arrive and the assertions below are empty).
    cards  = capture_turbo_stream_broadcasts("lights")
    heroes = capture_turbo_stream_broadcasts("light_K")

    # /switches list card on the shared "lights" stream carries the rendered card HTML.
    # Probe INSIDE the <template> (not the target= attribute) so an empty/broken render
    # would fail: LightCardComponent renders the light name "Lampe".
    assert cards.any? { |s| s["target"] == "light_card_K" && s.at_css("template")&.inner_html&.include?("Lampe") },
           "Expected a turbo-stream replace targeting light_card_K carrying the rendered card on the 'lights' stream"
    # ...and the detail page hero on the per-light stream: PowerComponent always renders the An/Aus pills.
    assert heroes.any? { |s| s["target"] == "light_power" && s.at_css("template")&.inner_html&.include?("Aus") },
           "Expected a turbo-stream replace targeting light_power carrying the rendered hero on the 'light_K' stream"
  end

  test "broadcasts render the bare component, not the full application layout" do
    Light.create!(key: "K", name: "Lampe", zones: [])

    @sub.handle(topic("K"), JSON.generate("on" => true, "brightness" => 55, "reachable" => true))

    # The channel-level broadcast must pass layout: false; otherwise the component
    # is wrapped in the app layout (header + nav) and replacing #light_power injects
    # a whole second navigation into the page (duplicated menu bug).
    (capture_turbo_stream_broadcasts("light_K") + capture_turbo_stream_broadcasts("lights")).each do |s|
      html = s.at_css("template")&.inner_html.to_s
      assert_not_includes html, "app-header", "Broadcast leaked the application layout into the turbo stream"
      assert_not_includes html, "Hauptnavigation", "Broadcast leaked the navigation into the turbo stream"
    end
  end

  test "state ignores invalid JSON" do
    assert_nothing_raised { @sub.handle(topic("K"), "x{") }
    assert_equal 0, LightState.count
  end

  test "state survives an ActiveRecord error instead of propagating" do
    LightState.stub :record_state, ->(*) { raise ActiveRecord::StatementInvalid, "database is locked" } do
      assert_nothing_raised do
        @sub.handle(topic("K"), JSON.generate("on" => true, "reachable" => true))
      end
    end
  end
end
