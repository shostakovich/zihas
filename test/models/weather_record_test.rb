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
end
