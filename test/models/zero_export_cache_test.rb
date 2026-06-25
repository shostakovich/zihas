require "test_helper"

class ZeroExportCacheTest < ActiveSupport::TestCase
  Reader = Struct.new(:floor_values, :median_values, keyword_init: true) do
    attr_reader :floor_calls, :median_calls

    def guaranteed_floor_w
      @floor_calls = floor_calls.to_i + 1
      floor_values.shift
    end

    def median_consumption_w
      @median_calls = median_calls.to_i + 1
      median_values.shift
    end
  end

  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    @cache = ZeroExportCache.new(cache: @store)
  end

  test "floor_w caches the reader floor for the slow ttl" do
    reader = Reader.new(floor_values: [ 85.0, 200.0 ], median_values: [])

    assert_in_delta 85.0, @cache.floor_w(reader), 0.001
    assert_in_delta 85.0, @cache.floor_w(reader), 0.001
    assert_equal 1, reader.floor_calls
  end

  test "median_w caches the reader median for the median ttl" do
    reader = Reader.new(floor_values: [], median_values: [ 240.0, 800.0 ])

    assert_in_delta 240.0, @cache.median_w(reader), 0.001
    assert_in_delta 240.0, @cache.median_w(reader), 0.001
    assert_equal 1, reader.median_calls
  end

  test "median_w uses a 60 second ttl" do
    recording_store = Minitest::Mock.new
    recording_store.expect(:fetch, 240.0, [ ZeroExportCache::MEDIAN_CACHE_KEY ], expires_in: 60.seconds)
    cache = ZeroExportCache.new(cache: recording_store)
    reader = Reader.new(floor_values: [], median_values: [ 240.0 ])

    assert_in_delta 240.0, cache.median_w(reader), 0.001
    recording_store.verify
  end

  test "last write state is missing until remembered" do
    last = @cache.last_write
    assert last.missing?

    decision = ZeroExportController::Decision.new(state: :normal, target_w: 240)
    at = Time.zone.local(2026, 6, 20, 12, 0, 0)

    @cache.remember_write(decision, at)
    @cache.remember_state(decision)

    last = @cache.last_write
    assert_equal :normal, last.state
    assert_equal 240, last.target_w
    assert_equal at, last.at
    refute last.missing?
    assert_equal :normal, @cache.previous_state
  end

  test "failure counter increments and resets" do
    assert_equal 1, @cache.increment_failures
    assert_equal 2, @cache.increment_failures

    @cache.reset_failures

    assert_equal 1, @cache.increment_failures
  end
end
