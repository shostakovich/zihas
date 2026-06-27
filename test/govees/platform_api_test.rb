# test/govees/platform_api_test.rb
require "test_helper"
require "govees/platform_api"

class GoveesPlatformApiTest < ActiveSupport::TestCase
  BASE = "https://openapi.api.govee.com"

  setup { @api = Govees::PlatformApi.new(api_key: "k-123") }

  test "devices returns the data array and sends the api key header" do
    stub = stub_request(:get, "#{BASE}/router/api/v1/user/devices")
      .with(headers: { "Govee-API-Key" => "k-123" })
      .to_return(status: 200, body: JSON.generate("code" => 200, "message" => "success",
        "data" => [ { "sku" => "H60B0", "device" => "AA", "deviceName" => "Up" } ]))
    devices = @api.devices
    assert_equal "H60B0", devices.first["sku"]
    assert_requested stub
  end

  test "state flattens capabilities into an instance=>value hash" do
    stub_request(:post, "#{BASE}/router/api/v1/device/state")
      .to_return(status: 200, body: JSON.generate("code" => 200, "payload" => { "capabilities" => [
        { "instance" => "powerSwitch", "state" => { "value" => 1 } },
        { "instance" => "online",      "state" => { "value" => true } },
        { "instance" => "rippleLightToggle", "state" => { "value" => 0 } } ] }))
    st = @api.state(sku: "H60B0", device: "AA")
    assert_equal 1, st["powerSwitch"]
    assert_equal true, st["online"]
    assert_equal 0, st["rippleLightToggle"]
  end

  test "control returns true on body code 200" do
    stub_request(:post, "#{BASE}/router/api/v1/device/control")
      .to_return(status: 200, body: JSON.generate("code" => 200, "msg" => "success"))
    assert_equal true,
      @api.control(sku: "H60B0", device: "AA", type: "devices.capabilities.on_off",
                   instance: "powerSwitch", value: 1)
  end

  test "raises Error when the body code is not 200" do
    stub_request(:get, "#{BASE}/router/api/v1/user/devices")
      .to_return(status: 200, body: JSON.generate("code" => 401, "message" => "bad key"))
    assert_raises(Govees::PlatformApi::Error) { @api.devices }
  end

  test "raises Error on HTTP 5xx" do
    stub_request(:get, "#{BASE}/router/api/v1/user/devices").to_return(status: 500, body: "boom")
    assert_raises(Govees::PlatformApi::Error) { @api.devices }
  end
end
