require "test_helper"

class ConsumptionReaderTest < ActiveSupport::TestCase
  Plug = Struct.new(:id, :role, keyword_init: true)

  def plugs
    [ Plug.new(id: "bkw",    role: :producer),
      Plug.new(id: "fridge", role: :consumer),
      Plug.new(id: "tv",     role: :consumer) ]
  end

  setup { Sample.delete_all }

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

  test "no consumer plugs: consumption is nil, floor is zero" do
    reader = ConsumptionReader.new(plugs: [], now: Time.at(1_000_000))
    assert_nil reader.current_consumption_w
    assert_equal 0.0, reader.guaranteed_floor_w
  end
end
