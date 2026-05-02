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

  def sequence_client(readings_by_plug)
    counts = Hash.new(0)
    client = Object.new
    client.define_singleton_method(:fetch) do |plug|
      readings = readings_by_plug.fetch(plug.id)
      idx = [ counts[plug.id], readings.length - 1 ].min
      counts[plug.id] += 1
      readings[idx]
    end
    client
  end

  def capture_broadcasts
    broadcasts = []
    server = ActionCable.server
    original = server.method(:broadcast)
    server.define_singleton_method(:broadcast) do |stream, payload|
      broadcasts << [ stream, payload ]
    end
    begin
      yield broadcasts
    ensure
      server.define_singleton_method(:broadcast, original)
    end
  end

  test "successful tick inserts one row per plug" do
    @poller.tick
    assert_equal 2, Sample.count
    assert_equal %w[bkw fridge], Sample.pluck(:plug_id).sort
  end

  test "successful tick broadcasts one bundled message for changed plugs" do
    capture_broadcasts do |broadcasts|
      @poller.tick

      assert_equal 1, broadcasts.length
      stream, payload = broadcasts.first
      assert_equal "dashboard", stream
      assert_equal @now.to_i, payload[:ts]
      assert_equal %w[bkw fridge], payload[:plugs].map { |plug| plug[:plug_id] }.sort
    end
  end

  test "unchanged rounded power is not broadcast again" do
    capture_broadcasts do |broadcasts|
      @poller.tick
      @now += 5
      @poller.tick

      assert_equal 1, broadcasts.length
    end
  end

  test "tick broadcasts only plugs whose rounded power changed" do
    clients = {
      "bkw" => sequence_client(
        "bkw" => [
          ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0),
          ShellyClient::Reading.new(apower_w: 101.0, aenergy_wh: 501.0),
        ]
      ),
      "fridge" => sequence_client(
        "fridge" => [
          ShellyClient::Reading.new(apower_w: 0.0, aenergy_wh: 500.0),
          ShellyClient::Reading.new(apower_w: 0.0, aenergy_wh: 500.1),
        ]
      ),
    }
    @poller = Poller.new(
      plugs:        @plugs,
      clients:      clients,
      logger:       @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:        -> { @now },
    )

    capture_broadcasts do |broadcasts|
      @poller.tick
      @now += 5
      @poller.tick

      assert_equal 2, broadcasts.length
      changed = broadcasts.last.last[:plugs]
      assert_equal [ "bkw" ], changed.map { |plug| plug[:plug_id] }
      assert_equal 101.0, changed.first[:apower_w]
    end
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

  test "duplicate ts is handled gracefully without raising" do
    Sample.create!(plug_id: "bkw", ts: @now.to_i, apower_w: 1.0, aenergy_wh: 1.0)
    assert_nothing_raised { @poller.tick }
    assert_equal 1, Sample.where(plug_id: "bkw", ts: @now.to_i).count
  end

  test "all plugs fail and no samples are saved" do
    failing = Object.new
    def failing.fetch(_plug) = raise(ShellyClient::Error, "boom")
    @poller = Poller.new(
      plugs:        @plugs,
      clients:      @plugs.to_h { |p| [p.id, failing] },
      logger:       @logger,
      breaker_opts: { threshold: 1, probe_seconds: 30 },
      clock:        -> { @now },
    )
    @poller.tick
    assert_equal 0, Sample.count
  end

  test "stop! prevents further ticks in run loop" do
    ticked = 0
    @poller.define_singleton_method(:tick) { ticked += 1; stop! }
    @poller.run(0)
    assert_equal 1, ticked
  end

  test "poller recovers after breaker reopens" do
    call_count = 0
    recovering_client = Object.new
    recovering_client.define_singleton_method(:fetch) do |_plug|
      call_count += 1
      raise ShellyClient::Error, "boom" if call_count <= 2
      ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    end

    @poller = Poller.new(
      plugs:        @plugs,
      clients:      @plugs.to_h { |p| [p.id, recovering_client] },
      logger:       @logger,
      breaker_opts: { threshold: 1, probe_seconds: 30 },
      clock:        -> { @now },
    )

    @poller.tick        # both plugs fail → both breakers open (threshold: 1)
    assert_equal 0, Sample.count

    @now += 31          # advance past probe_seconds
    @poller.tick        # probe succeeds → breakers close, samples saved
    assert_equal 2, Sample.count
    assert_match(/recovered/, @log_io.string)
  end
end
