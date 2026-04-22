require "test_helper"
require "shelly_client"
require "config_loader"
require "json"

class ShellyClientTest < Minitest::Test
  def setup
    @client = ShellyClient.new(timeout: 2)
    @plug   = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer,
                                         driver: :shelly, host: "192.168.1.192")
  end

  def shelly_response
    { "id" => 0, "apower" => 342.5, "aenergy" => { "total" => 12_345.67 } }.to_json
  end

  def test_parses_successful_response
    stub_request(:get, "http://192.168.1.192/rpc/Switch.GetStatus?id=0")
      .to_return(status: 200, body: shelly_response, headers: { "Content-Type" => "application/json" })

    reading = @client.fetch(@plug)
    assert_in_delta 342.5, reading.apower_w
    assert_in_delta 12_345.67, reading.aenergy_wh
  end

  def test_raises_on_non_200
    stub_request(:get, /.*/).to_return(status: 503, body: "boot")
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_timeout
    stub_request(:get, /.*/).to_timeout
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_connection_refused
    stub_request(:get, /.*/).to_raise(Errno::ECONNREFUSED)
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_malformed_json
    stub_request(:get, /.*/).to_return(status: 200, body: "not json")
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_missing_fields
    stub_request(:get, /.*/).to_return(status: 200, body: "{}")
    assert_raises(ShellyClient::Error) { @client.fetch(@plug) }
  end
end
