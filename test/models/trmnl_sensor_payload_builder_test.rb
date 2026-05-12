require "test_helper"

class TrmnlSensorPayloadBuilderTest < ActiveSupport::TestCase
  setup do
    SensorReading.delete_all
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @indoor1 = ConfigLoader::SensorCfg.new(id: "INDOOR1", name: "Wohnzimmer",
                                            type: :meter_pro_co2, room: "Wohnzimmer")
    @indoor2 = ConfigLoader::SensorCfg.new(id: "INDOOR2", name: "Küche",
                                            type: :meter_pro_co2, room: "Küche")
    @outdoor = ConfigLoader::SensorCfg.new(id: "OUTDOOR", name: "Balkon",
                                            type: :outdoor_meter, room: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "h", port: 1, topic_prefix: "p")
    plug = ConfigLoader::PlugCfg.new(id: "bkw", name: "BKW", role: :producer, driver: :shelly, ain: nil)
    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32, timezone: "Europe/Berlin",
      mqtt: mqtt, fritz_poll: nil, plugs: [ plug ], fritz_box: nil, weather: nil,
      switchbot: ConfigLoader::SwitchbotCfg.new(token: "t", secret: "s"),
      sensors: [ @indoor1, @indoor2, @outdoor ],
      trmnl: ConfigLoader::TrmnlCfg.new(energy_webhook_url: nil,
                                         sensors_webhook_url: "https://example.test/x")
    )
    @now = Time.utc(2026, 5, 12, 14, 56, 0) # 16:56 Europe/Berlin
  end

  def reading(device_id, taken_at, co2: nil, temp: 20.0, humidity: 40, battery: 80)
    SensorReading.create!(device_id: device_id, taken_at: taken_at,
                          temperature: temp, humidity: humidity, co2: co2, battery_pct: battery)
  end

  test "build returns one sensor entry per configured sensor, in config order" do
    reading("INDOOR1", @now - 4.minutes, co2: 1230, temp: 22.4, humidity: 48)
    reading("INDOOR2", @now - 3.minutes, co2: 740,  temp: 21.8, humidity: 51)
    reading("OUTDOOR", @now - 5.minutes, temp: 12.4, humidity: 64, battery: 73)

    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    sensors = payload.fetch("merge_variables").fetch("sensors")
    assert_equal %w[INDOOR1 INDOOR2 OUTDOOR], sensors.map { |s| s["id"] }
    assert_equal %w[Wohnzimmer Küche Balkon], sensors.map { |s| s["name"] }
    assert_equal %w[indoor indoor outdoor], sensors.map { |s| s["type"] }
  end

  test "indoor sensor exposes ppm primary, ampel and unit" do
    reading("INDOOR1", @now - 4.minutes, co2: 1230, temp: 22.4, humidity: 48)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }

    assert_equal 1230,        s["primary"]
    assert_equal "ppm CO₂",   s["unit"]
    assert_equal "warn",      s["ampel"]
    assert_in_delta 22.4,     s["temperature"], 0.01
    assert_equal 48,          s["humidity"]
    refute s["offline"]
  end

  test "outdoor sensor exposes °C primary, no ampel, single-decimal float" do
    reading("OUTDOOR", @now - 5.minutes, temp: 12.4, humidity: 64)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "OUTDOOR" }

    assert_in_delta 12.4, s["primary"], 0.01
    assert_equal "°C", s["unit"]
    assert_nil s["ampel"]
    assert_equal 64, s["humidity"]
  end

  test "trend has 12 buckets oldest first; newer readings land later than older ones" do
    reading("INDOOR1", @now - 5.minutes,            co2: 1230)
    reading("INDOOR1", @now - 50.minutes,           co2: 950)
    reading("INDOOR1", @now - 2.hours - 10.minutes, co2: 700)

    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert_equal 12, s["trend"].length
    non_null = s["trend"].compact
    assert_includes non_null, 1230
    assert_includes non_null, 700
    # Newest reading should sit later in the array than the oldest.
    assert s["trend"].index(1230) > s["trend"].index(700)
  end

  test "trend buckets without readings are null, not zero" do
    reading("INDOOR1", @now - 5.minutes, co2: 1230)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert_includes s["trend"], nil
    assert_equal 1230, s["trend"].last
  end

  test "trend_min and trend_max bracket the non-null trend values" do
    reading("INDOOR1", @now - 5.minutes, co2: 1230)
    reading("INDOOR1", @now - 50.minutes, co2: 950)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    non_null = s["trend"].compact
    assert_equal non_null.min, s["trend_min"]
    assert_equal non_null.max, s["trend_max"]
  end

  test "age_label is German pre-formatted relative time" do
    reading("INDOOR1", @now - 4.minutes, co2: 800)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert_equal "vor 4 Min", s["age_label"]
  end

  test "battery_low is true at or below 20%" do
    reading("INDOOR1", @now - 1.minute, co2: 800, battery: 14)
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert s["battery_low"]
    assert_equal 14, s["battery_pct"]
  end

  test "offline sensor reports offline=true and no trend" do
    reading("INDOOR1", @now - 2.hours, co2: 800) # last reading 2h ago > 30min
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert s["offline"]
    assert_nil s["primary"]
    assert_equal [], s["trend"]
    assert_nil s["ampel"]
  end

  test "completely missing sensor (no rows ever) is offline" do
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    s = payload["merge_variables"]["sensors"].find { |x| x["id"] == "INDOOR1" }
    assert s["offline"]
    assert_nil s["primary"]
  end

  test "stand reflects local time of the most recent reading" do
    reading("INDOOR1", @now - 4.minutes, co2: 1230) # 16:52 local
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    assert_equal "16:52", payload["merge_variables"]["stand"]
  end

  test "stand falls back to current local time when no readings exist" do
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    assert_equal "16:56", payload["merge_variables"]["stand"]
  end

  test "serialized payload stays under the TRMNL 2 kB limit for three sensors with full trend" do
    [ "INDOOR1", "INDOOR2", "OUTDOOR" ].each do |id|
      12.times do |i|
        reading(id, @now - (i * 15).minutes, co2: 800 + i, temp: 20.0 + (i * 0.1))
      end
    end
    payload = TrmnlSensorPayloadBuilder.new(config: @config, now: @now).build
    bytes = payload.to_json.bytesize
    assert bytes <= 2048, "payload is #{bytes} B, exceeds 2 kB limit"
  end
end
