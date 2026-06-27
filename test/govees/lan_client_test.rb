# test/govees/lan_client_test.rb
require "test_helper"
require "govees/lan_client"

class GoveesLanClientTest < ActiveSupport::TestCase
  # Fake UDP socket records what was sent instead of touching the network.
  class FakeSocket
    attr_reader :sent, :sockopt_calls
    def initialize = (@sent = []; @sockopt_calls = [])
    def send(data, _flags, host, port) = @sent << { data: data, host: host, port: port }
    def setsockopt(*args) = @sockopt_calls << args
    def close = nil
  end

  setup do
    @sock   = FakeSocket.new
    @client = Govees::LanClient.new(socket_factory: -> { @sock })
  end

  test "turn sends a Govee turn datagram to port 4003" do
    @client.turn("192.168.8.184", true)
    msg = @sock.sent.first
    assert_equal "192.168.8.184", msg[:host]
    assert_equal 4003, msg[:port]
    assert_equal({ "cmd" => "turn", "data" => { "value" => 1 } }, JSON.parse(msg[:data])["msg"])
  end

  test "color sends colorwc with rgb and zero kelvin" do
    @client.color("1.2.3.4", r: 10, g: 20, b: 30)
    data = JSON.parse(@sock.sent.first[:data]).dig("msg", "data")
    assert_equal({ "r" => 10, "g" => 20, "b" => 30 }, data["color"])
    assert_equal 0, data["colorTemInKelvin"]
  end

  test "color_temp sends colorwc with kelvin and zero rgb" do
    @client.color_temp("1.2.3.4", 3000)
    data = JSON.parse(@sock.sent.first[:data]).dig("msg", "data")
    assert_equal 3000, data["colorTemInKelvin"]
  end

  test "parse_status maps onOff/brightness/color/kelvin/sku" do
    payload = JSON.generate("msg" => { "data" => {
      "onOff" => 1, "brightness" => 42, "color" => { "r" => 1, "g" => 2, "b" => 3 },
      "colorTemInKelvin" => 3500, "sku" => "H60B0" } })
    s = Govees::LanClient.parse_status(payload)
    assert_equal true, s.on
    assert_equal 42, s.brightness
    assert_equal 3, s.color_b
    assert_equal 3500, s.color_temp_k
    assert_equal "H60B0", s.sku
  end

  test "parse_status returns nil for non-status payloads" do
    assert_nil Govees::LanClient.parse_status(JSON.generate("msg" => { "data" => {} }))
    assert_nil Govees::LanClient.parse_status("not-json{")
  end

  test "parse_scan extracts ip, mac and sku from a scan reply" do
    payload = JSON.generate("msg" => { "cmd" => "scan", "data" => {
      "ip" => "192.168.8.184", "device" => "14:AB:DB:48:44:06:4B:60", "sku" => "H60B0" } })
    assert_equal({ ip: "192.168.8.184", mac: "14:AB:DB:48:44:06:4B:60", sku: "H60B0" },
                 Govees::LanClient.parse_scan(payload))
  end

  test "discover sends scan_request to multicast 239.255.255.250 port 4001" do
    @client.discover
    msg = @sock.sent.first
    assert_not_nil msg, "expected discover to send a datagram"
    assert_equal "239.255.255.250", msg[:host]
    assert_equal 4001, msg[:port]
    assert_equal Govees::LanClient.scan_request, msg[:data]
  end

  test "discover sets IP_MULTICAST_TTL on the socket before sending" do
    @client.discover
    # Verify setsockopt was called with IPPROTO_IP + IP_MULTICAST_TTL
    assert @sock.sockopt_calls.any? { |args|
      args[0] == Socket::IPPROTO_IP && args[1] == Socket::IP_MULTICAST_TTL
    }, "expected IP_MULTICAST_TTL to be set"
  end
end
