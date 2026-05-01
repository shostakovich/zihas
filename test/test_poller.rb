require "test_helper"
require "poller"
require "config_loader"
require "logger"
require "stringio"

class PollerTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all

    @log_io = StringIO.new
    @logger  = Logger.new(@log_io)
    @now     = 1_700_000_000.0

    @plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, host: "10.0.0.1", ain: nil),
      ConfigLoader::PlugCfg.new(id: "fridge",  name: "Fridge", role: :consumer, driver: :shelly, host: "10.0.0.2", ain: nil),
    ]

    @poller = Poller.new(
      plugs:        @plugs,
      clients:      @plugs.to_h { |p| [ p.id, fake_client ] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
  end

  def fake_client
    client = Object.new
    def client.fetch(_plug) = ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    client
  end

  def failing_client(id_to_fail)
    client = Object.new
    client.define_singleton_method(:fetch) do |plug|
      raise ShellyClient::Error, "boom" if plug.id == id_to_fail
      ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    end
    client
  end

  test "successful tick inserts one row per plug" do
    @poller.tick
    assert_equal 2, Sample.count
    assert_equal %w[bkw fridge], Sample.pluck(:plug_id).sort
  end

  test "failing plug does not block others" do
    @poller = Poller.new(
      plugs:        @plugs,
      clients:      @plugs.to_h { |p| [ p.id, failing_client("bkw") ] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
    @poller.tick
    assert_equal 1, Sample.count
    assert_equal "fridge", Sample.first.plug_id
  end

  test "breaker opens after threshold failures" do
    @poller = Poller.new(
      plugs:        @plugs,
      clients:      @plugs.to_h { |p| [ p.id, failing_client("bkw") ] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
    3.times { @poller.tick }
    assert_match(/opening breaker.*bkw/i, @log_io.string)
  end

  test "breaker state change is only logged once" do
    @poller = Poller.new(
      plugs:        @plugs,
      clients:      @plugs.to_h { |p| [ p.id, failing_client("bkw") ] },
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )
    10.times { @poller.tick }
    assert_equal 1, @log_io.string.scan(/opening breaker/).length
  end

  test "timestamp stored as unix seconds" do
    @poller.tick
    assert_equal @now.to_i, Sample.order(:ts).first.ts
  end
end
