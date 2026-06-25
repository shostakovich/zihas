require "test_helper"

class PresetsControllerTest < ActionDispatch::IntegrationTest
  setup { Preset.delete_all }

  test "index lists presets" do
    Preset.create!(name: "Warm 20%", brightness: 20, color_temp_k: 2700)
    get presets_url
    assert_response :success
    assert_match "Warm 20%", @response.body
  end

  test "create adds a preset" do
    assert_difference -> { Preset.count }, 1 do
      post presets_url, params: { preset: { name: "Hell", brightness: 100, on: true } }
    end
    assert_redirected_to presets_url
  end

  test "destroy removes a preset" do
    preset = Preset.create!(name: "Weg")
    assert_difference -> { Preset.count }, -1 do
      delete preset_url(preset)
    end
  end
end
