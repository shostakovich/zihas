require "test_helper"

class TrmnlPayloadBuilderTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      mqtt: mqtt,
      fritz_poll: nil,
      plugs: [ plug_bkw, plug_fridge ],
      fritz_box: nil,
      weather: nil,
      trmnl_webhook_url: nil,
    )
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @midnight_local = @tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i
  end

  test "build returns merge_variables hash with today aggregate fields" do
    Sample.create!(plug_id: "bkw",    ts: @midnight_local + 60,   apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw",    ts: @midnight_local + 3600, apower_w: 0, aenergy_wh: 1000.0)
    Sample.create!(plug_id: "fridge", ts: @midnight_local + 60,   apower_w: 0, aenergy_wh: 500.0)
    Sample.create!(plug_id: "fridge", ts: @midnight_local + 3600, apower_w: 0, aenergy_wh: 1100.0)

    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")

    assert_in_delta 1.00,  mv["pv_kwh"],     0.001
    assert_in_delta 0.60,  mv["cons_kwh"],   0.001
    assert_in_delta 0.40,  mv["bilanz_kwh"], 0.001
    assert_kind_of Integer, mv["autarky"]
    assert_kind_of Integer, mv["self_use"]
  end

  test "build returns zeros when no samples exist" do
    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")
    assert_equal 0.0, mv["pv_kwh"]
    assert_equal 0.0, mv["cons_kwh"]
    assert_equal 0.0, mv["bilanz_kwh"]
    assert_equal 0,   mv["autarky"]
    assert_equal 0,   mv["self_use"]
  end

  test "build returns 48 half-hourly pv_w/cons_w arrays aligned to local hours" do
    local_now = @tz.utc_to_local(Time.now.utc)
    minute = local_now.min < 30 ? 0 : 30
    slot_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, minute, 0)
    end_ts   = @tz.local_to_utc(slot_floor_local).to_i + 1800  # upcoming half-hour boundary
    start_ts = end_ts - 86_400

    # Bucket index 10 covers start_ts + 10*1800 .. start_ts + 11*1800 (30 min slot).
    bucket_start = start_ts + 10 * 1800
    (0...1800).step(300) do |dt|
      Sample.create!(plug_id: "bkw",    ts: bucket_start + dt, apower_w: 600.0, aenergy_wh: 0.0)
      Sample.create!(plug_id: "fridge", ts: bucket_start + dt, apower_w: 200.0, aenergy_wh: 0.0)
    end

    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")

    assert_equal 48, mv["pv_w"].length
    assert_equal 48, mv["cons_w"].length
    assert(mv["pv_w"].all? { |v| v.is_a?(Integer) })
    assert(mv["cons_w"].all? { |v| v.is_a?(Integer) })

    # bucket 10: avg producer 600 W, avg consumer 200 W (constant across the bucket).
    assert_in_delta 600, mv["pv_w"][10],   5
    assert_in_delta 200, mv["cons_w"][10], 5

    (0...48).each do |i|
      next if i == 10
      assert_equal 0, mv["pv_w"][i],   "pv_w bucket #{i}"
      assert_equal 0, mv["cons_w"][i], "cons_w bucket #{i}"
    end
  end

  test "build returns 48 zero buckets when no samples exist" do
    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")
    assert_equal Array.new(48, 0), mv["pv_w"]
    assert_equal Array.new(48, 0), mv["cons_w"]
  end

  test "build sets ts to the max Sample.ts inside the 24h window" do
    local_now = @tz.utc_to_local(Time.now.utc)
    minute = local_now.min < 30 ? 0 : 30
    slot_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, minute, 0)
    end_ts = @tz.local_to_utc(slot_floor_local).to_i + 1800
    newest_ts = end_ts - 300 # 5 minutes before the upcoming half-hour boundary
    Sample.create!(plug_id: "bkw", ts: newest_ts, apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw", ts: newest_ts - 3600, apower_w: 0, aenergy_wh: 0.0)

    payload = TrmnlPayloadBuilder.new(config: @config).build
    assert_equal newest_ts, payload["merge_variables"]["ts"]
  end

  test "build falls back to Time.now.to_i when no samples exist" do
    before = Time.now.to_i
    payload = TrmnlPayloadBuilder.new(config: @config).build
    after = Time.now.to_i
    ts = payload["merge_variables"]["ts"]
    assert ts >= before, "ts (#{ts}) should be >= before (#{before})"
    assert ts <= after,  "ts (#{ts}) should be <= after (#{after})"
  end

  test "serialized payload stays under TRMNL's 2 kB webhook limit" do
    local_now = @tz.utc_to_local(Time.now.utc)
    hour_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
    end_ts   = @tz.local_to_utc(hour_floor_local).to_i + 3600
    start_ts = end_ts - 86_400

    (start_ts...end_ts).step(300) do |t|
      Sample.create!(plug_id: "bkw",    ts: t, apower_w: 999.0, aenergy_wh: 0.0)
      Sample.create!(plug_id: "fridge", ts: t, apower_w: 999.0, aenergy_wh: 0.0)
    end

    payload = TrmnlPayloadBuilder.new(config: @config).build
    bytes = payload.to_json.bytesize
    assert bytes <= 2048, "payload is #{bytes} B, exceeds TRMNL's 2 kB limit"
  end
end
