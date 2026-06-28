# test/components/lights/color_panel_component_test.rb
require "test_helper"

class Lights::ColorPanelComponentTest < ViewComponent::TestCase
  def panel(light:, state: nil)
    Lights::ColorPanelComponent.new(snapshot: LightSnapshot.new(light: light, state: state))
  end

  test "renders the swatch palette and the colour panel tab" do
    light = Light.new(key: "K1", name: "Lampe", zones: [])
    rendered = render_inline(panel(light: light))

    assert rendered.css("div.ld-panel[data-tab='color']").any?
    assert_equal 8, rendered.css("button.ld-sw").length
    assert_includes rendered.to_html, "Farbe"
  end

  test "zone lamps get the Welle + Seite label" do
    zone_light = Light.new(key: "K2", name: "Uplighter",
                           zones: %w[bottomLightToggle sideLightToggle])
    rendered = render_inline(panel(light: zone_light))
    assert_includes rendered.to_html, "Farbe · Welle + Seite"
  end

  test "the colour-wheel input defaults to the current hex" do
    light = Light.new(key: "K3", name: "Lampe", zones: [])
    state = LightState.new(light_key: "K3", color_r: 255, color_g: 107, color_b: 61)
    rendered = render_inline(panel(light: light, state: state))
    assert_equal "#ff6b3d", rendered.css("input[type='color']").first["value"]
  end
end
