# test/models/light_test.rb
require "test_helper"

class LightTest < ActiveSupport::TestCase
  test "valid with a name and a device-id key" do
    assert Light.new(name: "Stehlampe", key: "14ABDB4844064B60").valid?
  end

  test "requires a name" do
    refute Light.new(name: "", key: "14ABDB4844064B60").valid?
  end

  test "requires a key" do
    refute Light.new(name: "Stehlampe", key: "").valid?
  end

  test "key must be unique" do
    Light.create!(name: "Eins", key: "14ABDB4844064B60")
    refute Light.new(name: "Zwei", key: "14ABDB4844064B60").valid?
  end

  test "key rejects non-alphanumeric characters" do
    refute Light.new(name: "X", key: "14:AB:DB").valid?
  end

  test "key is stored verbatim (case preserved)" do
    light = Light.create!(name: "Mixed", key: "14abDB4844064b60")
    assert_equal "14abDB4844064b60", light.reload.key
  end

  test "to_param is the key" do
    light = Light.create!(name: "Bad", key: "A1B2C3D4E5F60001")
    assert_equal "A1B2C3D4E5F60001", light.to_param
  end

  test "optionally belongs to a room" do
    room  = Room.create!(name: "Salon")
    light = Light.create!(name: "Salon Lampe", key: "A1B2C3D4E5F60002", room: room)
    assert_equal room, light.room
    assert_includes room.lights, light
  end
end
