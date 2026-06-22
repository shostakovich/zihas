require "test_helper"

class ConsumptionReaderTest < ActiveSupport::TestCase
  Plug = Struct.new(:id, :role, keyword_init: true)

  def plugs
    [ Plug.new(id: "bkw",    role: :producer),
      Plug.new(id: "fridge", role: :consumer),
      Plug.new(id: "tv",     role: :consumer) ]
  end

  setup do
    Sample.delete_all
    @original_time_zone = Time.zone
    Time.zone = "Europe/Berlin"
  end

  teardown { Time.zone = @original_time_zone }

  test "current_consumption_w sums latest fresh consumer samples, ignores producer" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 10, apower_w: 100, aenergy_wh: 1)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5,  apower_w: 120, aenergy_wh: 1) # latest wins
    Sample.create!(plug_id: "tv",     ts: now.to_i - 5,  apower_w: 30,  aenergy_wh: 1)
    Sample.create!(plug_id: "bkw",    ts: now.to_i - 5,  apower_w: 500, aenergy_wh: 1) # producer, ignored
    reader = ConsumptionReader.new(plugs: plugs, now: now, stale_after_s: 120)
    assert_in_delta 150.0, reader.current_consumption_w
  end

  test "current_consumption_w drops stale samples" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5,   apower_w: 120, aenergy_wh: 1)
    Sample.create!(plug_id: "tv",     ts: now.to_i - 300, apower_w: 30,  aenergy_wh: 1) # stale
    reader = ConsumptionReader.new(plugs: plugs, now: now, stale_after_s: 120)
    assert_in_delta 120.0, reader.current_consumption_w
  end

  test "current_consumption_w is nil when all samples are stale" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 300, apower_w: 120, aenergy_wh: 1) # stale
    Sample.create!(plug_id: "tv",     ts: now.to_i - 400, apower_w: 30,  aenergy_wh: 1) # stale
    reader = ConsumptionReader.new(plugs: plugs, now: now, stale_after_s: 120)
    assert_nil reader.current_consumption_w
  end

  test "current_consumption_w is nil when there are no samples at all" do
    reader = ConsumptionReader.new(plugs: plugs, now: Time.at(1_000_000), stale_after_s: 120)
    assert_nil reader.current_consumption_w
  end

  test "current_consumption_w is 0.0 (not nil) when a fresh sample reads zero" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 5, apower_w: 0, aenergy_wh: 1) # fresh, zero
    reader = ConsumptionReader.new(plugs: plugs, now: now, stale_after_s: 120)
    assert_equal 0.0, reader.current_consumption_w
  end

  test "guaranteed_floor_w is the minimum 5-min total over 24h" do
    now = Time.at(1_000_000)
    # bucket A (low total = 100): -1000s
    Sample.create!(plug_id: "fridge", ts: now.to_i - 1000, apower_w: 100, aenergy_wh: 1)
    Sample.create!(plug_id: "tv",     ts: now.to_i - 1000, apower_w: 0,   aenergy_wh: 1)
    # bucket B (high total = 300, 15 min later): -100s
    Sample.create!(plug_id: "fridge", ts: now.to_i - 100,  apower_w: 200, aenergy_wh: 1)
    Sample.create!(plug_id: "tv",     ts: now.to_i - 100,  apower_w: 100, aenergy_wh: 1)
    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_in_delta 100.0, reader.guaranteed_floor_w
  end

  test "guaranteed_floor_w ignores samples older than 24h" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 100,    apower_w: 250, aenergy_wh: 1)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 90_000, apower_w: 10,  aenergy_wh: 1) # >24h
    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_in_delta 250.0, reader.guaranteed_floor_w
  end

  test "median_consumption_w rejects one high 5-minute spike" do
    now = Time.at(1_000_000)
    [ 120, 120, 800, 120, 120 ].each_with_index do |total, i|
      ts = now.to_i - (25 - i * 5).minutes
      Sample.create!(plug_id: "fridge", ts: ts, apower_w: total, aenergy_wh: 1)
    end

    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_in_delta 120.0, reader.median_consumption_w, 0.001
  end

  test "median_consumption_w sums consumer plugs per bucket" do
    now = Time.at(1_000_000)
    [ [ 60, 40 ], [ 80, 40 ], [ 200, 400 ], [ 70, 50 ], [ 90, 30 ] ].each_with_index do |(fridge, tv), i|
      ts = now.to_i - (25 - i * 5).minutes
      Sample.create!(plug_id: "fridge", ts: ts, apower_w: fridge, aenergy_wh: 1)
      Sample.create!(plug_id: "tv",     ts: ts, apower_w: tv,     aenergy_wh: 1)
    end

    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_in_delta 120.0, reader.median_consumption_w, 0.001
  end

  test "median_consumption_w returns nil when the 30-minute window is empty" do
    now = Time.at(1_000_000)
    Sample.create!(plug_id: "fridge", ts: now.to_i - 31.minutes, apower_w: 120, aenergy_wh: 1)

    reader = ConsumptionReader.new(plugs: plugs, now: now)
    assert_nil reader.median_consumption_w
  end

  test "no consumer plugs: consumption is nil, floor is zero" do
    reader = ConsumptionReader.new(plugs: [], now: Time.at(1_000_000))
    assert_nil reader.current_consumption_w
    assert_equal 0.0, reader.guaranteed_floor_w
    assert_nil reader.median_consumption_w
  end

  test "night_base_w returns P20 of recent night buckets" do
    # The most recent night (within NIGHT_BASE_DAYS=7, excluding edge hours) for
    # Berlin/2026-06-20 runs ~22:32-03:42 local. 01:00-01:45 local is well inside.
    # 10 five-minute buckets, consumer total (fridge + tv) per bucket:
    # [60, 85, 85, 85, 85, 85, 85, 95, 110, 150] -> sorted P20 (index 1) = 85.0
    base = Time.zone.local(2026, 6, 20, 1, 0, 0)
    bucket_totals = [ 60, 85, 85, 85, 85, 85, 85, 95, 110, 150 ]
    bucket_totals.each_with_index do |total, i|
      ts = (base + i * 300).to_i
      fridge_w = total / 2.0
      tv_w     = total - fridge_w
      Sample.create!(plug_id: "fridge", ts: ts, apower_w: fridge_w, aenergy_wh: 1)
      Sample.create!(plug_id: "tv",     ts: ts, apower_w: tv_w,     aenergy_wh: 1)
    end

    reader = ConsumptionReader.new(plugs: plugs, now: Time.zone.local(2026, 6, 20, 10, 0, 0))
    assert_in_delta 85.0,
      reader.night_base_w(lat: 52.52, lon: 13.405, timezone: "Europe/Berlin", days: 7, fallback_w: 120),
      0.001
  end

  test "night_base_w falls back when there is no night data" do
    reader = ConsumptionReader.new(plugs: plugs, now: Time.zone.local(2026, 6, 20, 10, 0, 0))
    assert_in_delta 120.0,
      reader.night_base_w(lat: 52.52, lon: 13.405, timezone: "Europe/Berlin", days: 7, fallback_w: 120),
      0.001
  end
end
