# test/govees/state_store_test.rb
require "test_helper"
require "govees/state_store"

class GoveesStateStoreTest < ActiveSupport::TestCase
  setup do
    @now   = 1000.0
    @store = Govees::StateStore.new(pending_window_s: 5.0, clock: -> { @now })
  end

  test "record_command publishes optimistically and marks pending" do
    pub = @store.record_command("K", on: true, brightness: 50)
    assert_equal true, pub[:on]
    assert_equal 50, pub[:brightness]
    assert_equal :pending, @store.status("K")
  end

  test "matching lan read-back within window confirms to synced" do
    @store.record_command("K", on: true, brightness: 50)
    res = @store.apply_telemetry("K", { on: true, brightness: 50, reachable: true }, source: :lan)
    assert_equal :synced, @store.status("K")
    refute res[:needs_api_clarification]
  end

  test "deviating lan read-back within window is ignored as not-yet-applied" do
    @store.record_command("K", on: true, brightness: 50)
    res = @store.apply_telemetry("K", { on: true, brightness: 10, reachable: true }, source: :lan)
    assert_equal 50, @store.published("K")[:brightness], "optimistic value held"
    assert_equal :pending, @store.status("K")
    refute res[:needs_api_clarification]
  end

  test "off telemetry is adopted immediately even against an on optimistic state" do
    @store.record_command("K", on: true, brightness: 50)
    @now += 10 # past the pending window
    res = @store.apply_telemetry("K", { on: false, reachable: true }, source: :lan)
    assert_equal false, @store.published("K")[:on]
    assert_equal :synced, @store.status("K")
    refute res[:needs_api_clarification]
  end

  test "on+deviation from lan after window requests api clarification" do
    @store.record_command("K", on: true, brightness: 50)
    @now += 10
    res = @store.apply_telemetry("K", { on: true, brightness: 80, reachable: true }, source: :lan)
    assert res[:needs_api_clarification]
    assert_equal :reconciling, @store.status("K")
  end

  test "api telemetry is authoritative and adopted" do
    @store.record_command("K", on: true, brightness: 50)
    @now += 10
    @store.apply_telemetry("K", { on: true, brightness: 80, reachable: true }, source: :lan)
    res = @store.apply_telemetry("K", { on: true, brightness: 80, color_temp_k: 3000,
                                        reachable: true, zone_states: { "ripple" => true } }, source: :api)
    assert_equal 80, @store.published("K")[:brightness]
    assert_equal({ "ripple" => true }, @store.published("K")[:zone_states])
    assert_equal :synced, @store.status("K")
    refute res[:needs_api_clarification]
  end
end
