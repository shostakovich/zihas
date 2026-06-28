# test/govees/cassette_scrubber_test.rb
require "test_helper"
require "govees/cassette_scrubber"

class GoveesCassetteScrubberTest < ActiveSupport::TestCase
  # Minimal fake interaction object that VCR would provide
  class FakeMsg
    attr_accessor :body

    def initialize(body)
      @body = body
    end
  end

  FakeInteraction = Struct.new(:request, :response)

  def build_interaction(req_body, resp_body)
    req  = FakeMsg.new(req_body)
    resp = FakeMsg.new(resp_body)
    FakeInteraction.new(req, resp)
  end

  # ── scrub! replaces MAC address ─────────────────────────────────────────────

  test "scrub! replaces a MAC address in the response body" do
    body   = '{"device":"AA:BB:CC:DD:EE:FF","other":"value"}'
    ia     = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    assert_includes ia.response.body, "AA:BB:CC:DD:EE:FF"
    refute_includes ia.response.body, "AA:BB:CC:DD:EE:EE"  # placeholder stays
  end

  test "scrub! replaces an arbitrary real MAC address in the response body" do
    body = '{"device":"12:34:56:78:9A:BC"}'
    ia   = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    assert_includes ia.response.body, Govees::CassetteScrubber::PLACEHOLDER_MAC
    refute_includes ia.response.body, "12:34:56:78:9A:BC"
  end

  test "scrub! fully replaces an 8-octet Govee device id (no real bytes leak)" do
    body = '{"device":"AB:CD:EF:12:34:56:78:90"}'
    ia   = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    refute_includes ia.response.body, "AB:CD:EF:12:34:56:78:90"
    refute_includes ia.response.body, "78:90"  # trailing octets must not survive
  end

  test "scrub! replaces a device id regardless of format via the device key" do
    body = '{"data":[{"device":"DEADBEEF","sku":"H60B0"},{"device":"11:22:33:44","sku":"H60B0"}]}'
    ia   = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    devs = JSON.parse(ia.response.body)["data"].map { |d| d["device"] }
    refute_includes devs, "DEADBEEF"
    refute_includes devs, "11:22:33:44"
    assert devs.all? { |d| d == Govees::CassetteScrubber::PLACEHOLDER_MAC }
  end

  # ── scrub! replaces 16-hex device key ───────────────────────────────────────

  test "scrub! replaces a bare 16-hex id outside the device key" do
    body = '{"note":"ABCDEF0123456789"}'  # 16-hex not under a device key
    ia   = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    assert_includes ia.response.body, Govees::CassetteScrubber::PLACEHOLDER_KEY16
    refute_includes ia.response.body, "ABCDEF0123456789"
  end

  # ── scrub! rewrites deviceName to "Lampe" ───────────────────────────────────

  test "scrub! rewrites deviceName to Lampe in the response body" do
    body = '{"deviceName":"Meine Wohnzimmerlampe","sku":"H60B0"}'
    ia   = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    parsed = JSON.parse(ia.response.body)
    assert_equal "Lampe", parsed["deviceName"]
    assert_equal "H60B0", parsed["sku"]
  end

  test "scrub! rewrites deviceName in nested arrays" do
    body = '{"data":[{"deviceName":"Real Name","sku":"H60B0"},{"deviceName":"Other","sku":"H60B1"}]}'
    ia   = build_interaction("{}", body)
    Govees::CassetteScrubber.scrub!(ia)
    parsed = JSON.parse(ia.response.body)
    assert parsed["data"].all? { |d| d["deviceName"] == "Lampe" }
  end

  # ── scrub! also touches the request body ────────────────────────────────────

  test "scrub! scrubs the request body too" do
    req_body = '{"payload":{"device":"12:34:56:78:9A:BC"}}'
    ia       = build_interaction(req_body, "{}")
    Govees::CassetteScrubber.scrub!(ia)
    assert_includes ia.request.body, Govees::CassetteScrubber::PLACEHOLDER_MAC
    refute_includes ia.request.body, "12:34:56:78:9A:BC"
  end

  # ── non-JSON bodies are returned unchanged ───────────────────────────────────

  test "scrub_names returns non-JSON body unchanged" do
    result = Govees::CassetteScrubber.scrub_names("not json at all")
    assert_equal "not json at all", result
  end

  # ── nil body is skipped without error ───────────────────────────────────────

  test "scrub! skips nil body without raising" do
    req  = FakeMsg.new(nil)
    resp = FakeMsg.new('{"deviceName":"Real"}')
    ia   = FakeInteraction.new(req, resp)
    assert_nothing_raised { Govees::CassetteScrubber.scrub!(ia) }
    assert_equal "Lampe", JSON.parse(ia.response.body)["deviceName"]
  end
end
