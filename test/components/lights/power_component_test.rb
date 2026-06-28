# test/components/lights/power_component_test.rb
require "test_helper"

class Lights::PowerComponentTest < ViewComponent::TestCase
  def snapshot(light:, state: nil)
    LightSnapshot.new(light: light, state: state)
  end

  test "renders the hero with on/off pills and the power id" do
    light = Light.new(key: "K1", name: "Stehlampe", sku: "H607C")
    state = LightState.new(light_key: "K1", on: true)
    rendered = render_inline(Lights::PowerComponent.new(snapshot: snapshot(light: light, state: state)))

    assert rendered.css("div#light_power").any?
    assert rendered.css("div.ld-lamp.plush-floorlamp").any?
    assert_includes rendered.to_html, "An"
    assert_includes rendered.to_html, "Aus"
  end

  test "shows the zones row only for zone lamps" do
    zone_light = Light.new(key: "K2", name: "Uplighter", sku: "H60B0",
                           zones: %w[bottomLightToggle sideLightToggle])
    rendered = render_inline(Lights::PowerComponent.new(snapshot: snapshot(light: zone_light)))
    assert rendered.css("div.ld-zones-row").any?
    assert rendered.css("form#zone_bottomLightToggle").any?

    simple = Light.new(key: "K3", name: "Lampe", sku: "H607C", zones: [])
    rendered2 = render_inline(Lights::PowerComponent.new(snapshot: snapshot(light: simple)))
    assert rendered2.css("div.ld-zones-row").none?
  end
end
