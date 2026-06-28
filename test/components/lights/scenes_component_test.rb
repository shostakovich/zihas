# test/components/lights/scenes_component_test.rb
require "test_helper"

class Lights::ScenesComponentTest < ViewComponent::TestCase
  test "lists firmware scenes with a deterministic gradient preview" do
    light = Light.new(key: "K1", name: "Lampe", firmware_scenes: %w[Forest Aurora])
    rendered = render_inline(Lights::ScenesComponent.new(light: light))

    assert_includes rendered.to_html, "Govee-Szenen"
    assert_equal 2, rendered.css("button.ld-scene").length
    assert_includes rendered.to_html, "Forest"
    previews = rendered.css("span.ld-scene-prev").map { |n| n["style"] }
    assert previews.all? { |s| s.include?("linear-gradient") }
    refute_equal previews[0], previews[1]
  end

  test "shows an empty-state hint when there are no scenes" do
    light = Light.new(key: "K2", name: "Lampe", firmware_scenes: [])
    rendered = render_inline(Lights::ScenesComponent.new(light: light))

    assert rendered.css("button.ld-scene").none?
    assert_includes rendered.to_html, "Diese Lampe meldet keine Govee-Szenen."
  end
end
