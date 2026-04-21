require "test_helper"
require "poller"
require "db"
require "config_loader"
require "logger"
require "stringio"

class PollerTest < Minitest::Test
  def setup
    @db = DB.connect(":memory:")
    DB.migrate!(@db)

    @log_io = StringIO.new
    @logger = Logger.new(@log_io)

    @now = 1_700_000_000.0
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",    role: :producer, host: "10.0.0.1"),
      ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, host: "10.0.0.2"),
    ]

    @poller = Poller.new(
      plugs:    @plugs,
      db:       @db,
      client:   fake_client,
      logger:   @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:    -> { @now },
    )
  end

  def fake_client
    client = Object.new
    def client.fetch(host) = ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    client
  end

  def failing_client(host_to_fail)
    client = Object.new
    client.define_singleton_method(:fetch) do |host|
      raise ShellyClient::Error, "boom" if host == host_to_fail
      ShellyClient::Reading.new(apower_w: 100.0, aenergy_wh: 500.0)
    end
    client
  end

  def test_successful_tick_inserts_one_row_per_plug
    @poller.tick
    assert_equal 2, @db[:samples].count
    ids = @db[:samples].map(:plug_id).sort
    assert_equal %w[bkw fridge], ids
  end

  def test_failing_plug_does_not_block_others
    @poller = Poller.new(
      plugs:    @plugs,
      db:       @db,
      client:   failing_client("10.0.0.1"),
      logger:   @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:    -> { @now },
    )
    @poller.tick
    assert_equal 1, @db[:samples].count
    assert_equal "fridge", @db[:samples].first[:plug_id]
  end

  def test_breaker_opens_after_threshold
    @poller = Poller.new(
      plugs:    @plugs,
      db:       @db,
      client:   failing_client("10.0.0.1"),
      logger:   @logger,
      breaker_opts: { threshold: 3, probe_seconds: 30 },
      clock:    -> { @now },
    )
    3.times { @poller.tick }
    assert_match(/opening breaker.*bkw/i, @log_io.string)
  end

  def test_only_logs_state_changes
    failing = failing_client("10.0.0.1")
    @poller = Poller.new(plugs: @plugs, db: @db, client: failing, logger: @logger,
                         breaker_opts: { threshold: 3, probe_seconds: 30 }, clock: -> { @now })
    10.times { @poller.tick }
    opens = @log_io.string.scan(/opening breaker/).length
    assert_equal 1, opens
  end

  def test_timestamp_is_unix_seconds
    @poller.tick
    ts = @db[:samples].first[:ts]
    assert_equal @now.to_i, ts
  end
end
