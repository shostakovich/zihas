# test/govee_lan_client_test.rb
require "test_helper"
require "govee_lan_client"

class GoveeLanClientTest < ActiveSupport::TestCase
  class FakeSocket
    attr_reader :sent, :closed
    def initialize(bucket) = (@bucket = bucket; @closed = false)
    def send(msg, _flags, host, port) = @bucket << { msg: msg, host: host, port: port }
    def close = @closed = true
  end

  def client_with(bucket)
    GoveeLanClient.new(socket_factory: -> { FakeSocket.new(bucket) })
  end

  test "turn on sends the turn command to port 4003" do
    sent = []
    client_with(sent).turn("192.168.10.20", true)
    assert_equal 1, sent.length
    assert_equal "192.168.10.20", sent.first[:host]
    assert_equal 4003,            sent.first[:port]
    assert_equal({ "msg" => { "cmd" => "turn", "data" => { "value" => 1 } } },
                 JSON.parse(sent.first[:msg]))
  end

  test "turn off serializes value 0" do
    sent = []
    client_with(sent).turn("192.168.10.20", false)
    assert_equal 0, JSON.parse(sent.first[:msg]).dig("msg", "data", "value")
  end

  test "brightness serializes the value" do
    sent = []
    client_with(sent).brightness("192.168.10.20", 42)
    msg = JSON.parse(sent.first[:msg])["msg"]
    assert_equal "brightness", msg["cmd"]
    assert_equal 42, msg.dig("data", "value")
  end

  test "color serializes rgb with colorTemInKelvin 0" do
    sent = []
    client_with(sent).color("192.168.10.20", r: 255, g: 100, b: 0)
    data = JSON.parse(sent.first[:msg]).dig("msg", "data")
    assert_equal({ "r" => 255, "g" => 100, "b" => 0 }, data["color"])
    assert_equal 0, data["colorTemInKelvin"]
  end

  test "color_temp serializes the kelvin value" do
    sent = []
    client_with(sent).color_temp("192.168.10.20", 3000)
    assert_equal 3000, JSON.parse(sent.first[:msg]).dig("msg", "data", "colorTemInKelvin")
  end

  test "request_status sends devStatus" do
    sent = []
    client_with(sent).request_status("192.168.10.20")
    assert_equal "devStatus", JSON.parse(sent.first[:msg]).dig("msg", "cmd")
  end

  test "closes the socket after sending" do
    socket = nil
    GoveeLanClient.new(socket_factory: -> { socket = FakeSocket.new([]) })
                  .turn("192.168.10.20", true)
    assert socket.closed
  end

  test "parse_status maps a devStatus response" do
    payload = JSON.generate("msg" => { "cmd" => "devStatus", "data" => {
      "onOff" => 1, "brightness" => 60,
      "color" => { "r" => 10, "g" => 20, "b" => 30 },
      "colorTemInKelvin" => 0, "sku" => "H6076"
    } })
    s = GoveeLanClient.parse_status(payload)
    assert_equal true, s.on
    assert_equal 60,   s.brightness
    assert_equal 30,   s.color_b
    assert_equal "H6076", s.sku
  end

  test "parse_status returns nil for malformed payload" do
    assert_nil GoveeLanClient.parse_status("not-json{")
    assert_nil GoveeLanClient.parse_status(JSON.generate("foo" => 1))
  end

  test "custom command_port is used when sending" do
    sent = []
    GoveeLanClient.new(socket_factory: -> { FakeSocket.new(sent) }, command_port: 4010)
                  .turn("192.168.10.20", true)
    assert_equal 4010, sent.first[:port]
  end
end
