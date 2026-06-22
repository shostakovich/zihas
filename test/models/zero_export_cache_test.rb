require "test_helper"

class ZeroExportCacheTest < ActiveSupport::TestCase
  Reader = Struct.new(:floor_values, :median_values, :night_values, keyword_init: true) do
    attr_reader :floor_calls, :median_calls, :night_calls

    def guaranteed_floor_w
      @floor_calls = floor_calls.to_i + 1
      floor_values.shift
    end

    def median_consumption_w
      @median_calls = median_calls.to_i + 1
      median_values.shift
    end

    def night_base_w(**)
      @night_calls = night_calls.to_i + 1
      night_values.shift
    end
  end

  Weather = Struct.new(:lat, :lon, keyword_init: true)
  Config = Struct.new(:weather, :timezone, keyword_init: true)

  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    @cache = ZeroExportCache.new(cache: @store)
  end

  test "floor_w caches the reader floor for the slow ttl" do
    reader = Reader.new(floor_values: [ 85.0, 200.0 ], median_values: [], night_values: [])

    assert_in_delta 85.0, @cache.floor_w(reader), 0.001
    assert_in_delta 85.0, @cache.floor_w(reader), 0.001
    assert_equal 1, reader.floor_calls
  end

  test "median_w caches the reader median for the median ttl" do
    reader = Reader.new(floor_values: [], median_values: [ 240.0, 800.0 ], night_values: [])

    assert_in_delta 240.0, @cache.median_w(reader), 0.001
    assert_in_delta 240.0, @cache.median_w(reader), 0.001
    assert_equal 1, reader.median_calls
  end

  test "median_w uses a 60 second ttl" do
    recording_store = Minitest::Mock.new
    recording_store.expect(:fetch, 240.0, [ ZeroExportCache::MEDIAN_CACHE_KEY ], expires_in: 60.seconds)
    cache = ZeroExportCache.new(cache: recording_store)
    reader = Reader.new(floor_values: [], median_values: [ 240.0 ], night_values: [])

    assert_in_delta 240.0, cache.median_w(reader), 0.001
    recording_store.verify
  end

  test "night_base_w falls back to floor when weather is missing" do
    reader = Reader.new(floor_values: [], median_values: [], night_values: [ 120.0 ])
    config = Config.new(weather: nil, timezone: "Europe/Berlin")

    assert_in_delta 85.0, @cache.night_base_w(reader, config, 85.0), 0.001
    assert_nil reader.night_calls
  end

  test "night_base_w caches weather based reader value for the slow ttl" do
    reader = Reader.new(floor_values: [], median_values: [], night_values: [ 90.0, 120.0 ])
    config = Config.new(weather: Weather.new(lat: 52.52, lon: 13.405), timezone: "Europe/Berlin")

    assert_in_delta 90.0, @cache.night_base_w(reader, config, 85.0), 0.001
    assert_in_delta 90.0, @cache.night_base_w(reader, config, 85.0), 0.001
    assert_equal 1, reader.night_calls
  end

  test "last write state is missing until remembered" do
    last = @cache.last_write
    assert last.missing?

    decision = ZeroExportController::Decision.new(state: :pv_priority, target_w: 240, deadband_w: 50)
    at = Time.zone.local(2026, 6, 20, 12, 0, 0)

    @cache.remember_write(decision, at)
    @cache.remember_state(decision)

    last = @cache.last_write
    assert_equal :pv_priority, last.state
    assert_equal 240, last.target_w
    assert_equal at, last.at
    refute last.missing?
    assert_equal :pv_priority, @cache.previous_state
  end

  test "failure counter increments and resets" do
    assert_equal 1, @cache.increment_failures
    assert_equal 2, @cache.increment_failures

    @cache.reset_failures

    assert_equal 1, @cache.increment_failures
  end
end
