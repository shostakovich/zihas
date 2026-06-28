# test/govees/commander_test.rb
require "test_helper"
require "govees/commander"

class GoveesCommanderTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :published
    def initialize = @published = []
    def connect = self
    def publish(topic, payload) = @published << [ topic, payload ]
    def disconnect = nil
  end

  def light = Light.new(key: "K1", name: "L", zones: [])
  def cfg   = Struct.new(:host, :port).new("h", 1883)

  test "publishes a brightness verb to govees/<key>/set" do
    client = FakeClient.new
    Govees::Commander.set_brightness(light, value: 40, mqtt_config: cfg, mqtt_factory: -> { client })
    topic, payload = client.published.first
    assert_equal "govees/K1/set", topic
    assert_equal({ "brightness" => 40 }, JSON.parse(payload))
  end

  test "set_zone publishes a zone verb" do
    client = FakeClient.new
    Govees::Commander.set_zone(light, zone: "rippleLightToggle", on: true, mqtt_config: cfg, mqtt_factory: -> { client })
    assert_equal({ "zone" => { "name" => "rippleLightToggle", "on" => true } }, JSON.parse(client.published.first[1]))
  end

  test "raises Error when publish fails" do
    failing = Object.new.tap { |c| c.define_singleton_method(:connect) { raise "no broker" } }
    assert_raises(Govees::Commander::Error) do
      Govees::Commander.turn(light, on: true, mqtt_config: cfg, mqtt_factory: -> { failing })
    end
  end
end
