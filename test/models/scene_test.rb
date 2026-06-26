require "test_helper"

class SceneTest < ActiveSupport::TestCase
  setup do
    @light  = Light.create!(name: "Kino Lampe", key: "A1B2C3D4E5F60020")
    @preset = Preset.create!(name: "Warm 20%", brightness: 20, color_temp_k: 2700)
  end

  test "requires a name" do
    refute Scene.new(name: "").valid?
  end

  test "has entries mapping a light to a preset" do
    scene = Scene.create!(name: "Kino")
    scene.scene_entries.create!(light: @light, preset: @preset)
    assert_equal 1, scene.scene_entries.count
    entry = scene.scene_entries.first
    assert_equal @light,  entry.light
    assert_equal @preset, entry.preset
  end

  test "destroying a scene destroys its entries" do
    scene = Scene.create!(name: "Kino")
    scene.scene_entries.create!(light: @light, preset: @preset)
    assert_difference -> { SceneEntry.count }, -1 do
      scene.destroy
    end
  end
end
