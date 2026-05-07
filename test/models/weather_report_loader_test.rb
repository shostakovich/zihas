require "test_helper"
require "ostruct"

class WeatherReportLoaderTest < ActiveSupport::TestCase
  setup do
    WeatherRecord.delete_all
    @loader = WeatherReportLoader.new(lat: 48.15, lon: 11.26, timezone: "Europe/Berlin")
  end

  test "daily aggregates solar and resolves dominant icon per local day" do
    create_historic(Time.utc(2026, 5, 1, 6),  solar: 0.10, icon: "clear-day",         daytime: "day")
    create_historic(Time.utc(2026, 5, 1, 12), solar: 0.50, icon: "partly-cloudy-day", daytime: "day")
    create_historic(Time.utc(2026, 5, 1, 18), solar: 0.05, icon: "rain",              daytime: "day")
    create_historic(Time.utc(2026, 5, 1, 22), solar: 0.00, icon: "clear-night",       daytime: "night")

    daily = @loader.daily(Date.new(2026, 5, 1), Date.new(2026, 5, 1))

    assert_equal [ "2026-05-01" ], daily.keys
    assert_in_delta 0.65, daily["2026-05-01"][:solar_kwh_per_m2], 0.001
    # rain dominates day-only severity vs clear / partly-cloudy
    assert_equal "weather_rain_day.webp", daily["2026-05-01"][:asset_name]
    assert_equal "rain", daily["2026-05-01"][:alt]
  end

  test "daily skips days without records" do
    create_historic(Time.utc(2026, 5, 1, 12), solar: 0.4, icon: "clear-day", daytime: "day")

    daily = @loader.daily(Date.new(2026, 4, 30), Date.new(2026, 5, 2))

    assert_equal [ "2026-05-01" ], daily.keys
  end

  test "hourly returns one entry per historic record in range" do
    create_historic(Time.utc(2026, 5, 1, 10), solar: 0.40, icon: "clear-day", daytime: "day")
    create_historic(Time.utc(2026, 5, 1, 11), solar: 0.55, icon: "clear-day", daytime: "day")

    hourly = @loader.hourly(Date.new(2026, 5, 1), Date.new(2026, 5, 1))

    assert_equal 2, hourly.size
    assert_equal Time.utc(2026, 5, 1, 10).to_i, hourly.first[:ts]
    assert_in_delta 400.0, hourly.first[:solar_w_per_m2]
    assert_equal "weather_clear_day.webp", hourly.first[:asset_name]
  end

  test "from_app_config returns nil without weather lat/lon" do
    cfg = OpenStruct.new(weather: OpenStruct.new(lat: nil, lon: nil), timezone: "UTC")
    assert_nil WeatherReportLoader.from_app_config(cfg)
  end

  private

  def create_historic(ts, solar:, icon:, daytime:)
    WeatherRecord.create!(
      kind: "historic",
      timestamp: ts,
      lat: 48.15,
      lon: 11.26,
      solar: solar,
      icon: icon,
      daytime: daytime
    )
  end
end
