require "test_helper"

class Lights::ZoneComponentTest < ViewComponent::TestCase
  test "renders a toggle pill reflecting the on-state" do
    zone = Lights::Zone.new(key: "bottomLightToggle", label: "Leselicht", role: "main", on: true)
    rendered = render_inline(Lights::ZoneComponent.new(zone: zone, light_key: "K1"))

    assert rendered.css("button.ld-zone-btn.on").any?
    assert rendered.css("form#zone_bottomLightToggle").any?
    assert_equal "true", rendered.css("button").first["aria-pressed"]
    assert_includes rendered.to_html, "Leselicht"
  end

  test "off zone has no on-class and aria-pressed false" do
    zone = Lights::Zone.new(key: "sideLightToggle", label: "Seite", role: "side", on: false)
    rendered = render_inline(Lights::ZoneComponent.new(zone: zone, light_key: "K1"))

    assert rendered.css("button.ld-zone-btn").any?
    assert rendered.css("button.ld-zone-btn.on").none?
    assert_equal "false", rendered.css("button").first["aria-pressed"]
  end
end
