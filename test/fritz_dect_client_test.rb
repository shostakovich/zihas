require "test_helper"
require "fritz_dect_client"
require "config_loader"
require "digest"

class FritzDectClientTest < Minitest::Test
  HOST      = "192.168.178.1"
  USER      = "testuser"
  PASSWORD  = "testpass"
  AIN       = "11630 0206224"
  SID       = "abc123def456abcd"
  CHALLENGE = "deadbeef"

  def setup
    @client = FritzDectClient.new(host: HOST, user: USER, password: PASSWORD, timeout: 2)
    @plug   = ConfigLoader::PlugCfg.new(
      id: "krabbencomputer", name: "Test", role: :consumer,
      driver: :fritz_dect, ain: AIN,
    )
  end

  def md5_response
    md5 = Digest::MD5.hexdigest("#{CHALLENGE}-#{PASSWORD}".encode("UTF-16LE").b)
    "#{CHALLENGE}-#{md5}"
  end

  def challenge_xml
    %(<?xml version="1.0"?><SessionInfo><SID>0000000000000000</SID><Challenge>#{CHALLENGE}</Challenge></SessionInfo>)
  end

  def sid_xml
    %(<?xml version="1.0"?><SessionInfo><SID>#{SID}</SID><Challenge>#{CHALLENGE}</Challenge></SessionInfo>)
  end

  def stub_auth
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .to_return(status: 200, body: challenge_xml)
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .with(query: hash_including("username" => USER, "response" => md5_response))
      .to_return(status: 200, body: sid_xml)
  end

  def test_parses_successful_response
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower", "ain" => AIN, "sid" => SID))
      .to_return(status: 200, body: "342000\n")
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchenergy", "ain" => AIN, "sid" => SID))
      .to_return(status: 200, body: "12345\n")

    reading = @client.fetch(@plug)
    assert_in_delta 342.0, reading.apower_w
    assert_in_delta 12_345.0, reading.aenergy_wh
  end

  def test_zero_power_is_valid
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 200, body: "0\n")
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchenergy"))
      .to_return(status: 200, body: "1000\n")

    reading = @client.fetch(@plug)
    assert_in_delta 0.0, reading.apower_w
  end

  def test_reauths_on_403_and_retries
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 403).then
      .to_return(status: 200, body: "100000\n")
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchenergy"))
      .to_return(status: 200, body: "5000\n")

    reading = @client.fetch(@plug)
    assert_in_delta 100.0, reading.apower_w
    assert_in_delta 5_000.0, reading.aenergy_wh
  end

  def test_raises_on_permanent_403
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 403)

    err = assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
    assert_match(/403.*re-auth/i, err.message)
  end

  def test_raises_on_auth_failure
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .to_return(status: 200, body: challenge_xml)
    stub_request(:get, "http://#{HOST}/login_sid.lua")
      .with(query: hash_including("username" => USER))
      .to_return(status: 200,
                 body: %(<?xml version="1.0"?><SessionInfo><SID>0000000000000000</SID></SessionInfo>))

    err = assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
    assert_match(/authentication failed/i, err.message)
  end

  def test_raises_on_non_200_from_homeauto
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 503, body: "")

    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_blank_body
    stub_auth
    stub_request(:get, "http://#{HOST}/webservices/homeautoswitch.lua")
      .with(query: hash_including("switchcmd" => "getswitchpower"))
      .to_return(status: 200, body: "")

    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_timeout
    stub_request(:get, "http://#{HOST}/login_sid.lua").to_timeout
    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end

  def test_raises_on_connection_refused
    stub_request(:get, "http://#{HOST}/login_sid.lua").to_raise(Errno::ECONNREFUSED)
    assert_raises(FritzDectClient::Error) { @client.fetch(@plug) }
  end
end
