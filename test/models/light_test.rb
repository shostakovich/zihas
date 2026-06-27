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

  test "firmware_scenes defaults to an empty array" do
    light = Light.create!(name: "Decke", key: "A1B2C3D4E5F60100")
    assert_equal [], light.reload.firmware_scenes
  end

  test "firmware_scenes round-trips an array of names" do
    light = Light.create!(name: "Decke", key: "A1B2C3D4E5F60101",
                          firmware_scenes: %w[Forest Aurora])
    assert_equal %w[Forest Aurora], light.reload.firmware_scenes
  end

  test "plush_type maps known SKUs case-insensitively" do
    assert_equal "uplighter", Light.new(sku: "H60B0").plush_type
    assert_equal "floorlamp", Light.new(sku: "h607c").plush_type
    assert_equal "sconce",    Light.new(sku: "H6038").plush_type
    assert_equal "ceiling",   Light.new(sku: "H60A6").plush_type
  end

  test "plush_type falls back to generic for unknown or blank SKU" do
    assert_equal "generic", Light.new(sku: "H9999").plush_type
    assert_equal "generic", Light.new(sku: nil).plush_type
  end

  test "zones defaults to an empty array" do
    assert_equal [], Light.new.zones
  end

  test "zones round-trips a JSON array of toggle keys" do
    l = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
    assert_equal %w[bottomLightToggle rippleLightToggle], l.reload.zones
  end

  test "zone_lamp? is true only with two or more zones" do
    assert_not Light.new(zones: %w[bottomLightToggle]).zone_lamp?
    assert     Light.new(zones: %w[bottomLightToggle sideLightToggle]).zone_lamp?
  end

  test "ZONE_META labels the known uplighter toggles with a main role" do
    assert_equal "Leselicht", Light::ZONE_META["bottomLightToggle"][:label]
    assert_equal "main",      Light::ZONE_META["bottomLightToggle"][:role]
    assert_equal "side",      Light::ZONE_META["rippleLightToggle"][:role]
  end

  test "max_active_zones is 2 for the H60B0 uplighter and nil otherwise" do
    assert_equal 2,   Light.new(sku: "H60B0").max_active_zones
    assert_nil        Light.new(sku: "H607C").max_active_zones
  end
end
