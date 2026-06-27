# test/govees/device_registry_test.rb
require "test_helper"
require "govees/device_registry"

class GoveesDeviceRegistryTest < ActiveSupport::TestCase
  # Minimal fake API returning canned device + scene data.
  class FakeApi
    def devices
      [ { "sku" => "H60B0", "device" => "14:AB:DB:48:44:06:4B:60", "deviceName" => "Uplighter",
          "capabilities" => [
            { "type" => "devices.capabilities.color_setting",  "instance" => "colorRgb" },
            { "type" => "devices.capabilities.color_setting",  "instance" => "colorTemperatureK" },
            { "type" => "devices.capabilities.toggle",         "instance" => "rippleLightToggle" },
            { "type" => "devices.capabilities.toggle",         "instance" => "dreamViewToggle" },
            { "type" => "devices.capabilities.segment_color_setting", "instance" => "segmentedColorRgb" } ] },
        { "sku" => "H6038", "device" => "AA:BB:CC:DD:EE:FF:00:11", "deviceName" => "Sockellicht",
          "capabilities" => [ { "type" => "devices.capabilities.on_off", "instance" => "powerSwitch" } ] },
        { "sku" => "DreamViewScenic", "device" => "13955275", "deviceName" => "Abendrot",
          "capabilities" => [ { "type" => "devices.capabilities.on_off", "instance" => "powerSwitch" } ] } ]
    end
    def scenes(sku:, device:)
      [ { "name" => "Sunset", "value" => { "id" => 5, "paramId" => 9 } } ]
    end
  end

  setup { @reg = Govees::DeviceRegistry.new(api: FakeApi.new, logger: Logger.new(IO::NULL)) }

  test "refresh builds a device with colon-stripped key and capability flags" do
    @reg.refresh!
    d = @reg.find("14ABDB4844064B60")
    assert_equal "14:AB:DB:48:44:06:4B:60", d.api_id
    assert_equal "H60B0", d.sku
    assert_equal "Uplighter", d.name
    assert d.supports_color
    assert d.supports_color_temp
  end

  test "zones keep only Light::ZONE_META instances (segments and control toggles dropped)" do
    @reg.refresh!
    d = @reg.find("14ABDB4844064B60")
    assert_equal [ "rippleLightToggle" ], d.zones
  end

  test "scenes expose names and an internal id/paramId index" do
    @reg.refresh!
    d = @reg.find("14ABDB4844064B60")
    assert_equal [ "Sunset" ], d.scenes
    assert_equal({ id: 5, param_id: 9 }, d.scene_index["Sunset"])
  end

  test "power_only device is flagged and gets no zones or scenes" do
    @reg.refresh!
    d = @reg.find("AABBCCDDEEFF0011")
    assert d.power_only
    assert_empty d.zones
    assert_empty d.scenes
  end

  test "virtual scene devices (DreamViewScenic) are excluded from the registry" do
    @reg.refresh!
    assert_nil @reg.find("13955275"), "Abendrot is a virtual scene, not a lamp"
    assert_equal 2, @reg.all.size
  end

  test "record_lan_ip matches by colon-insensitive mac" do
    @reg.refresh!
    @reg.record_lan_ip("14:AB:DB:48:44:06:4B:60", "192.168.8.184")
    assert_equal "192.168.8.184", @reg.find("14ABDB4844064B60").ip
  end

  test "names map overrides device name and sets room, key normalised" do
    names = { "14:AB:DB:48:44:06:4B:60" => { name: "Wohnzimmer Uplighter", room: "Wohnzimmer" } }
    reg = Govees::DeviceRegistry.new(api: FakeApi.new, logger: Logger.new(IO::NULL), names: names)
    reg.refresh!
    d = reg.find("14ABDB4844064B60")
    assert_equal "Wohnzimmer Uplighter", d.name
    assert_equal "Wohnzimmer", d.room
  end

  test "names without room leaves room nil" do
    names = { "14ABDB4844064B60" => { name: "My Lamp", room: nil } }
    reg = Govees::DeviceRegistry.new(api: FakeApi.new, logger: Logger.new(IO::NULL), names: names)
    reg.refresh!
    d = reg.find("14ABDB4844064B60")
    assert_equal "My Lamp", d.name
    assert_nil d.room
  end

  test "empty name override falls back to API deviceName" do
    names = { "14ABDB4844064B60" => { name: "", room: nil } }
    reg = Govees::DeviceRegistry.new(api: FakeApi.new, logger: Logger.new(IO::NULL), names: names)
    reg.refresh!
    d = reg.find("14ABDB4844064B60")
    assert_equal "Uplighter", d.name
  end
end
