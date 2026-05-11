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

  test "build returns 24 hourly ev/es arrays aligned to local hours" do
    now_utc   = Time.now.utc.to_i
    local_now = @tz.utc_to_local(Time.at(now_utc).utc)
    hour_floor_local = Time.new(local_now.year, local_now.month, local_now.day, local_now.hour, 0, 0)
    end_ts   = @tz.local_to_utc(hour_floor_local).to_i + 3600  # upcoming local-hour boundary
    start_ts = end_ts - 86_400

    # Hour bucket index 5 is start_ts + 5*3600 .. start_ts + 6*3600.
    bucket_start = start_ts + 5 * 3600
    (0...3600).step(300) do |dt|
      Sample.create!(plug_id: "bkw",    ts: bucket_start + dt, apower_w: 600.0, aenergy_wh: 0.0)
      Sample.create!(plug_id: "fridge", ts: bucket_start + dt, apower_w: 200.0, aenergy_wh: 0.0)
    end

    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")

    assert_equal 24, mv["ev"].length
    assert_equal 24, mv["es"].length
    assert(mv["ev"].all? { |v| v.is_a?(Integer) })
    assert(mv["es"].all? { |v| v.is_a?(Integer) })

    # bucket 5: producer 600 W, consumer 200 W → overlap 200 Wh, feed-in 400 Wh
    assert_in_delta 200, mv["ev"][5], 5
    assert_in_delta 400, mv["es"][5], 5

    # all other buckets should be 0
    (0...24).each do |i|
      next if i == 5
      assert_equal 0, mv["ev"][i], "ev bucket #{i}"
      assert_equal 0, mv["es"][i], "es bucket #{i}"
    end
  end

  test "build returns 24 zero buckets when no samples exist" do
    payload = TrmnlPayloadBuilder.new(config: @config).build
    mv = payload.fetch("merge_variables")
    assert_equal Array.new(24, 0), mv["ev"]
    assert_equal Array.new(24, 0), mv["es"]
  end
end
