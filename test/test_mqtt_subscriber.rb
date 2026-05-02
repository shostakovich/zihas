require "test_helper"
require "mqtt_subscriber"
require "config_loader"
require "logger"
require "stringio"

class MqttSubscriberTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)
    @now    = 1_700_000_000.0

    @mqtt_config = ConfigLoader::MqttCfg.new(
      host: "localhost", port: 1883, topic_prefix: "shellies"
    )
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",   name: "Solar",  role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    ]
    @subscriber = MqttSubscriber.new(
      mqtt_config: @mqtt_config,
      plugs:       @plugs,
      logger:      @logger,
      clock:       -> { @now },
    )
  end

  def status_payload(apower:, total:)
    JSON.generate({ "apower" => apower, "aenergy" => { "total" => total } })
  end

  def capture_broadcasts
    broadcasts = []
    server = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) { |stream, payload| broadcasts << [ stream, payload ] }
    yield broadcasts
  ensure
    server.define_singleton_method(:broadcast, original)
  end

  test "handle_message inserts sample for known plug" do
    @subscriber.handle_message("shellies/bkw/status/switch:0",
                               status_payload(apower: 300.0, total: 1234.5))
    assert_equal 1, Sample.count
    s = Sample.first
    assert_equal "bkw", s.plug_id
    assert_equal @now.to_i, s.ts
    assert_in_delta 300.0, s.apower_w
    assert_in_delta 1234.5, s.aenergy_wh
  end

  test "handle_message warns and skips unknown plug" do
    @subscriber.handle_message("shellies/unknown/status/switch:0",
                               status_payload(apower: 1.0, total: 1.0))
    assert_equal 0, Sample.count
    assert_match(/unknown plug.*unknown/i, @log_io.string)
  end

  test "handle_message ignores invalid JSON" do
    assert_nothing_raised do
      @subscriber.handle_message("shellies/bkw/status/switch:0", "not-json{")
    end
    assert_equal 0, Sample.count
    assert_match(/invalid json/i, @log_io.string)
  end

  test "handle_message handles duplicate ts gracefully" do
    Sample.create!(plug_id: "bkw", ts: @now.to_i, apower_w: 1.0, aenergy_wh: 1.0)
    assert_nothing_raised do
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
    end
    assert_equal 1, Sample.where(plug_id: "bkw").count
  end

  test "handle_message broadcasts immediately on first message after startup" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      assert_equal 1, broadcasts.length
      stream, payload = broadcasts.first
      assert_equal "dashboard", stream
      plugs = payload[:plugs]
      assert_equal 1, plugs.length
      assert_equal "bkw",      plugs.first[:plug_id]
      assert_equal "Solar",    plugs.first[:name]
      assert_equal "producer", plugs.first[:role]
      assert_in_delta 300.0,   plugs.first[:apower_w]
    end
  end

  test "handle_message batches messages within the 5-second window" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      @now += 1
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 350.0, total: 1234.6))
      assert_equal 1, broadcasts.length
    end
  end

  test "handle_message sends a new broadcast after the 5-second interval elapses" do
    capture_broadcasts do |broadcasts|
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      @now += 5
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 350.0, total: 1234.6))
      assert_equal 2, broadcasts.length
    end
  end

  test "handle_message merges multiple plugs into one broadcast" do
    capture_broadcasts do |broadcasts|
      # First message triggers immediate broadcast (cold start)
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 300.0, total: 1234.5))
      # Fridge message arrives within the window — buffered
      @now += 1
      @subscriber.handle_message("shellies/fridge/status/switch:0",
                                 status_payload(apower: 50.0, total: 100.0))
      # Next bkw message arrives after interval — triggers broadcast with both plugs
      @now += 5
      @subscriber.handle_message("shellies/bkw/status/switch:0",
                                 status_payload(apower: 310.0, total: 1234.6))

      assert_equal 2, broadcasts.length
      _, payload = broadcasts.last
      plug_ids = payload[:plugs].map { |p| p[:plug_id] }
      assert_includes plug_ids, "fridge"
      assert_includes plug_ids, "bkw"
    end
  end
end
