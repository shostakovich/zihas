require "test_helper"

class WeatherRecordTest < ActiveSupport::TestCase
  setup { WeatherRecord.delete_all }

  test "requires supported kind and daytime" do
    record = WeatherRecord.new(
      kind: "current",
      timestamp: Time.utc(2026, 5, 4, 12),
      lat: 52.52,
      lon: 13.405,
      daytime: "day"
    )

    assert record.valid?
  end

  test "rejects unsupported kind" do
    record = WeatherRecord.new(
      kind: "live",
      timestamp: Time.utc(2026, 5, 4, 12),
      lat: 52.52,
      lon: 13.405,
      daytime: "day"
    )

    assert_not record.valid?
    assert_includes record.errors[:kind], "is not included in the list"
  end

  test "returns asset name" do
    record = WeatherRecord.new(icon: "cloudy", daytime: "night")

    assert_equal "weather_cloudy_night.webp", record.asset_name
  end

  test "solar_w_per_m2 converts current 10-minute kWh/m² to average W/m²" do
    record = WeatherRecord.new(kind: "current", solar: 0.072)

    assert_in_delta 432.0, record.solar_w_per_m2
  end

  test "solar_w_per_m2 converts forecast hourly kWh/m² to average W/m²" do
    record = WeatherRecord.new(kind: "forecast", solar: 0.48)

    assert_in_delta 480.0, record.solar_w_per_m2
  end

  test "solar_w_per_m2 converts historic hourly kWh/m² to average W/m²" do
    record = WeatherRecord.new(kind: "historic", solar: 0.32)

    assert_in_delta 320.0, record.solar_w_per_m2
  end

  test "solar_w_per_m2 returns nil when raw solar is nil" do
    record = WeatherRecord.new(kind: "forecast", solar: nil)

    assert_nil record.solar_w_per_m2
  end
end
