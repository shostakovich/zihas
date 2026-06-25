# test/models/light_test.rb
require "test_helper"

class LightTest < ActiveSupport::TestCase
  test "valid with name and ip" do
    assert Light.new(name: "Stehlampe", ip_address: "192.168.10.20").valid?
  end

  test "requires name and ip_address" do
    refute Light.new(name: "", ip_address: "").valid?
  end

  test "generates key from name on create" do
    light = Light.create!(name: "Wohnzimmer Stehlampe", ip_address: "192.168.10.20")
    assert_equal "wohnzimmer_stehlampe", light.key
  end

  test "transliterates umlauts in the key" do
    light = Light.create!(name: "Küche Über", ip_address: "192.168.10.21")
    assert_equal "kueche_ueber", light.key
  end

  test "appends a numeric suffix on key collision" do
    Light.create!(name: "Flur", ip_address: "192.168.10.22")
    second = Light.create!(name: "Flur", ip_address: "192.168.10.23")
    assert_equal "flur_2", second.key
  end

  test "key is stable across a rename" do
    light = Light.create!(name: "Diele", ip_address: "192.168.10.24")
    light.update!(name: "Eingang")
    assert_equal "diele", light.key
  end

  test "to_param is the key" do
    light = Light.create!(name: "Bad", ip_address: "192.168.10.25")
    assert_equal "bad", light.to_param
  end

  test "optionally belongs to a room" do
    room  = Room.create!(name: "Salon")
    light = Light.create!(name: "Salon Lampe", ip_address: "192.168.10.26", room: room)
    assert_equal room, light.room
    assert_includes room.lights, light
  end
end
