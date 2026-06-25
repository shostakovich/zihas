require "test_helper"

class PresetTest < ActiveSupport::TestCase
  test "valid with a name" do
    assert Preset.new(name: "Warm 20%", brightness: 20, color_temp_k: 2700).valid?
  end

  test "requires a name" do
    refute Preset.new(name: "").valid?
  end
end
