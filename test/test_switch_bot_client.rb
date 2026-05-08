require "test_helper"
require "switch_bot_client"

class SwitchBotClientTest < Minitest::Test
  TOKEN  = "tok-123"
  SECRET = "sec-xyz"

  def setup
    @client = SwitchBotClient.new(token: TOKEN, secret: SECRET)
  end

  def test_device_status_meter_pro_co2_normalizes_fields
    stub_request(:get, "https://api.switch-bot.com/v1.1/devices/ABC/status")
      .to_return(status: 200, body: {
        statusCode: 100,
        message: "success",
        body: {
          deviceId: "ABC", deviceType: "MeterPro(CO2)", hubDeviceId: "HUB",
          temperature: 21.4, humidity: 52, CO2: 612, battery: 85, version: "V1.2"
        }
      }.to_json, headers: { "Content-Type" => "application/json" })

    data = @client.device_status("ABC")

    assert_in_delta 21.4, data[:temperature]
    assert_equal 52,  data[:humidity]
    assert_equal 612, data[:co2]
    assert_equal 85,  data[:battery_pct]
    assert_equal "V1.2", data[:firmware_version]
  end

  def test_device_status_outdoor_meter_has_nil_co2
    stub_request(:get, "https://api.switch-bot.com/v1.1/devices/OUT/status")
      .to_return(status: 200, body: {
        statusCode: 100,
        message: "success",
        body: {
          deviceId: "OUT", deviceType: "WoIOSensor", hubDeviceId: "HUB",
          temperature: 12.3, humidity: 71, battery: 100, version: "V4.2"
        }
      }.to_json, headers: { "Content-Type" => "application/json" })

    data = @client.device_status("OUT")

    assert_nil data[:co2]
    assert_in_delta 12.3, data[:temperature]
    assert_equal 71, data[:humidity]
    assert_equal 100, data[:battery_pct]
  end

  def test_device_status_sends_signed_headers
    captured = nil
    stub_request(:get, "https://api.switch-bot.com/v1.1/devices/X/status")
      .with { |req| captured = req.headers; true }
      .to_return(status: 200, body: { statusCode: 100, body: {
        deviceType: "MeterPro(CO2)", temperature: 1, humidity: 1, CO2: 1, battery: 1
      } }.to_json)

    @client.device_status("X")

    assert_equal TOKEN, captured["Authorization"]
    refute_nil captured["T"] || captured["t"]
    refute_nil captured["Nonce"] || captured["nonce"]
    refute_nil captured["Sign"] || captured["sign"]
  end

  def test_device_status_raises_on_non_success_status_code
    stub_request(:get, "https://api.switch-bot.com/v1.1/devices/X/status")
      .to_return(status: 200, body: { statusCode: 161, message: "device offline", body: {} }.to_json)

    err = assert_raises(SwitchBotClient::Error) { @client.device_status("X") }
    assert_match(/device offline/i, err.message)
  end

  def test_device_status_raises_on_http_error
    stub_request(:get, "https://api.switch-bot.com/v1.1/devices/X/status")
      .to_return(status: 500, body: "")

    err = assert_raises(SwitchBotClient::Error) { @client.device_status("X") }
    assert_match(/http 500/i, err.message)
  end
end
