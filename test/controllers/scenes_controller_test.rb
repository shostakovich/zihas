require "test_helper"

class ScenesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Scene.delete_all
    Light.delete_all
    Preset.delete_all
  end

  test "create adds a scene" do
    assert_difference -> { Scene.count }, 1 do
      post scenes_url, params: { scene: { name: "Kino" } }
    end
    assert_redirected_to scenes_url
  end

  test "apply issues a turn command per entry and responds" do
    scene  = Scene.create!(name: "Kino")
    light  = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60040")
    preset = Preset.create!(name: "Warm 20%", on: true, brightness: 20, color_temp_k: 2700)
    scene.scene_entries.create!(light: light, preset: preset)

    turns = []
    Govees::Commander.stub :turn, ->(l, **kw) { turns << [ l.key, kw[:on] ] } do
      Govees::Commander.stub :set_brightness, ->(*, **) { } do
        Govees::Commander.stub :set_color_temp, ->(*, **) { } do
          post apply_scene_url(scene)
        end
      end
    end
    assert_redirected_to scenes_url
    assert_equal [ [ "A1B2C3D4E5F60040", true ] ], turns
  end
end
