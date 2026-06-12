require "test_helper"
require "weather_sync"

class WeatherSyncTest < ActiveSupport::TestCase
  setup do
    WeatherRecord.delete_all
    DailyTotal.delete_all
    @config = ConfigLoader::Config.new(timezone: "Europe/Berlin", weather: ConfigLoader::WeatherCfg.new(lat: 52.52, lon: 13.405))
    @client = Minitest::Mock.new
    @sync = WeatherSync.new(config: @config, client: @client)
  end

  def weather_row(timestamp:)
    {
      timestamp: Time.parse(timestamp),
      source_id: 7003,
      temperature: 16.2,
      icon: "cloudy",
      daytime: "day"
    }
  end

  test "sync_current_keeps_one_current_row" do
    @client.expect(:current_weather, weather_row(timestamp: "2026-05-04T10:00:00+00:00"))
    @sync.sync_current

    @client.expect(:current_weather, weather_row(timestamp: "2026-05-04T10:15:00+00:00"))
    @sync.sync_current

    assert_equal 1, WeatherRecord.where(kind: "current").count
    assert_equal Time.parse("2026-05-04T10:15:00+00:00"), WeatherRecord.current.first.timestamp
  end

  test "historic_replaces_matching_forecast" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.parse("2026-05-04T10:00:00+00:00"), daytime: "day", icon: "cloudy")

    @client.expect(:weather_for_date, [ weather_row(timestamp: "2026-05-04T10:00:00+00:00") ], [ Date.new(2026, 5, 4) ])
    @sync.sync_historic_date(Date.new(2026, 5, 4))

    assert_equal 0, WeatherRecord.where(kind: "forecast").count
    assert_equal 1, WeatherRecord.where(kind: "historic").count
  end

  test "forecast_stops_on_range_end" do
    @client.expect(:weather_for_date, [ weather_row(timestamp: "2026-05-05T10:00:00+00:00") ], [ Date.new(2026, 5, 5) ])
    @client.expect(:weather_for_date, :range_end, [ Date.new(2026, 5, 6) ])

    @sync.sync_forecast(today: Date.new(2026, 5, 4), max_days: 3)

    assert_equal 1, WeatherRecord.where(kind: "forecast").count
  end

  test "backfills_daily_total_dates_without_historic_weather" do
    DailyTotal.create!(plug_id: "bkw", date: "2026-05-01", energy_wh: 1000)
    @client.expect(:weather_for_date, [ weather_row(timestamp: "2026-05-01T10:00:00+00:00") ], [ Date.new(2026, 5, 1) ])

    @sync.backfill_historic_from_daily_totals

    assert_equal 1, WeatherRecord.where(kind: "historic").count
  end
end
