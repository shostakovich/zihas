# test/components/lights/white_panel_component_test.rb
require "test_helper"

class Lights::WhitePanelComponentTest < ViewComponent::TestCase
  def panel(light:, state: nil)
    Lights::WhitePanelComponent.new(snapshot: LightSnapshot.new(light: light, state: state))
  end

  def preset_param(rendered, label)
    rendered.css("button.ld-preset").find { |b| b.text.strip == label }["data-light-detail-temp-param"]
  end

  test "renders the white panel with the lamp's slider range" do
    light = Light.new(key: "K1", name: "Floor", color_temp_min_k: 2200, color_temp_max_k: 6500, zones: [])
    rendered = render_inline(panel(light: light))

    slider = rendered.css("input.ld-white").first
    assert_equal "2200", slider["min"]
    assert_equal "6500", slider["max"]
    assert rendered.css("div.ld-panel[data-tab='white']").any?
  end

  test "presets span min..5400 with the midpoint in between (2200 lamp)" do
    light = Light.new(key: "K1", name: "Floor", color_temp_min_k: 2200, color_temp_max_k: 6500, zones: [])
    rendered = render_inline(panel(light: light))
    assert_equal "2200", preset_param(rendered, "Gemütlich")
    assert_equal "3800", preset_param(rendered, "Neutral")
    assert_equal "5400", preset_param(rendered, "Arbeiten")
  end

  test "presets adapt to a 2700 lamp" do
    light = Light.new(key: "K2", name: "Ceiling", color_temp_min_k: 2700, color_temp_max_k: 6500, zones: [])
    rendered = render_inline(panel(light: light))
    assert_equal "2700", preset_param(rendered, "Gemütlich")
    assert_equal "4100", preset_param(rendered, "Neutral")
    assert_equal "5400", preset_param(rendered, "Arbeiten")
  end

  test "presets stay within a lamp whose range tops out below PRESET_MAX_K" do
    light = Light.new(key: "K4", name: "Warm only", color_temp_min_k: 2200, color_temp_max_k: 4000, zones: [])
    rendered = render_inline(panel(light: light))
    assert_equal "2200", preset_param(rendered, "Gemütlich")
    assert_equal "3100", preset_param(rendered, "Neutral")
    assert_equal "4000", preset_param(rendered, "Arbeiten")
    # no preset may exceed the slider's own max
    rendered.css("button.ld-preset").each do |b|
      assert_operator b["data-light-detail-temp-param"].to_i, :<=, 4000
    end
  end

  test "the preset matching the current colour temperature is marked active" do
    light = Light.new(key: "K3", name: "Ceiling", color_temp_min_k: 2700, color_temp_max_k: 6500, zones: [])
    state = LightState.new(light_key: "K3", color_temp_k: 5400)
    rendered = render_inline(panel(light: light, state: state))

    active = rendered.css("button.ld-preset.ld-preset--active")
    assert_equal 1, active.length
    assert_equal "Arbeiten", active.first.text.strip
    assert_equal "true", active.first["aria-pressed"]
  end
end
