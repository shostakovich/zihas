# test/components/lights/light_card_component_test.rb
require "test_helper"

class Lights::LightCardComponentTest < ViewComponent::TestCase
  def card(attrs)
    light = Light.new(key: "K1", name: "Stehlampe", sku: "H607C")
    state = attrs.nil? ? nil : LightState.new(attrs.merge(light_key: "K1"))
    Lights::LightCardComponent.new(snapshot: LightSnapshot.new(light: light, state: state))
  end

  test "off card summarises as Aus and has no chip" do
    rendered = render_inline(card(on: false))
    assert rendered.css("div#light_card_K1.sw-offline").any?
    assert_includes rendered.to_html, "Aus"
    assert rendered.css("span.sw-watt-chip").none?
  end

  test "white-on card shows summary and a brightness chip" do
    rendered = render_inline(card(on: true, brightness: 60, color_temp_k: 2700))
    assert_includes rendered.to_html, "An · Weiß · 60 %"
    assert rendered.css("span.sw-watt-chip").any?
    assert_includes rendered.to_html, "60 %"
  end

  test "colour-on card derives the chip swatch from rgb" do
    rendered = render_inline(card(on: true, brightness: 40, color_r: 255, color_g: 107, color_b: 61))
    assert_includes rendered.to_html, "An · Farbe · 40 %"
    assert_includes rendered.to_html, "#ff6b3d"
  end
end
