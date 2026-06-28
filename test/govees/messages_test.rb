# test/govees/messages_test.rb
require "test_helper"
require "govees/messages"

class GoveesMessagesSetTest < ActiveSupport::TestCase
  M = Govees::Messages

  test "power to_wire uses on/off strings and round-trips" do
    assert_equal({ "power" => "on" },  M::Set::Power.new(on: true).to_wire)
    assert_equal({ "power" => "off" }, M::Set::Power.new(on: false).to_wire)
    assert_equal true, M::Set.parse("power" => "on").on
  end

  test "brightness round-trips as integer" do
    assert_equal({ "brightness" => 40 }, M::Set::Brightness.new(value: 40).to_wire)
    assert_equal 40, M::Set.parse("brightness" => 40).value
  end

  test "color carries an Rgb and round-trips" do
    wire = M::Set::Color.new(rgb: { r: 1, g: 2, b: 3 }).to_wire
    assert_equal({ "color" => { "r" => 1, "g" => 2, "b" => 3 } }, wire)
    parsed = M::Set.parse(wire)
    assert_equal [ 1, 2, 3 ], [ parsed.rgb.r, parsed.rgb.g, parsed.rgb.b ]
  end

  test "color_temp round-trips" do
    assert_equal({ "color_temp_k" => 3000 }, M::Set::ColorTemp.new(kelvin: 3000).to_wire)
    assert_equal 3000, M::Set.parse("color_temp_k" => 3000).kelvin
  end

  test "zone carries name + boolean on and round-trips" do
    wire = M::Set::Zone.new(name: "rippleLightToggle", on: true).to_wire
    assert_equal({ "zone" => { "name" => "rippleLightToggle", "on" => true } }, wire)
    z = M::Set.parse(wire)
    assert_equal [ "rippleLightToggle", true ], [ z.name, z.on ]
  end

  test "scene round-trips" do
    assert_equal({ "scene" => "Sunset" }, M::Set::Scene.new(name: "Sunset").to_wire)
    assert_equal "Sunset", M::Set.parse("scene" => "Sunset").name
  end

  test "parse returns nil for an unknown verb" do
    assert_nil M::Set.parse("wat" => 1)
  end
end

class GoveesMessagesStateTest < ActiveSupport::TestCase
  M = Govees::Messages

  test "from_hash defaults on=false and reachable=true when absent" do
    s = M::State.from_hash({})
    assert_equal false, s.on
    assert_equal true,  s.reachable
    assert_equal({ "on" => false, "reachable" => true }, s.to_wire)
  end

  test "to_wire emits only present optional fields" do
    s = M::State.from_hash(on: true, brightness: 60)
    assert_equal({ "on" => true, "reachable" => true, "brightness" => 60 }, s.to_wire)
  end

  test "nil color/color_temp_k are dropped (reset semantics from the store)" do
    s = M::State.from_hash(on: true, color: nil, color_temp_k: nil)
    refute s.to_wire.key?("color")
    refute s.to_wire.key?("color_temp_k")
  end

  test "color round-trips as an Rgb hash" do
    s = M::State.from_hash(on: true, color: { r: 1, g: 2, b: 3 })
    assert_equal({ "r" => 1, "g" => 2, "b" => 3 }, s.to_wire["color"])
    assert_equal 2, M::State.from_hash(s.to_wire).color.g
  end

  test "zone_states keep string keys and boolean values" do
    s = M::State.from_hash(on: true, zone_states: { "powerSwitch" => true })
    assert_equal({ "powerSwitch" => true }, s.to_wire["zone_states"])
  end
end

class GoveesMessagesConfigTest < ActiveSupport::TestCase
  M = Govees::Messages

  Dev = Struct.new(:sku, :name, :supports_color, :supports_color_temp, :zones, :scenes,
                   keyword_init: true)

  test "from_device emits the six curated wire fields" do
    dev = Dev.new(sku: "H60B0", name: "Uplighter", supports_color: true,
                  supports_color_temp: true, zones: [ "rippleLightToggle" ], scenes: [ "Sunset" ])
    w = M::Config.from_device(dev).to_wire
    assert_equal "H60B0", w["sku"]
    assert_equal true, w["supports_color"]
    assert_equal [ "rippleLightToggle" ], w["zones"]
    assert_equal [ "Sunset" ], w["scenes"]
  end

  test "from_hash defaults absent collections and flags" do
    c = M::Config.from_hash("sku" => "H60B0", "name" => "L")
    assert_equal [], c.zones
    assert_equal false, c.supports_color
  end
end
