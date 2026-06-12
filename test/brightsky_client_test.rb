require "test_helper"
require "brightsky_client"

class BrightskyClientTest < Minitest::Test
  def setup
    @client = BrightskyClient.new(lat: 52.52, lon: 13.405, timezone: "Europe/Berlin")
  end

  def test_fetches_current_weather
    stub_request(:get, "https://api.brightsky.dev/current_weather")
      .with(query: { lat: "52.52", lon: "13.405" })
      .to_return(status: 200, body: {
        weather: {
          timestamp: "2026-05-04T15:00:00+00:00",
          source_id: 303711,
          temperature: 16.2,
          condition: "dry",
          icon: "cloudy",
          cloud_cover: 88,
          wind_speed_10: 13.7,
          precipitation_10: 0.0,
          solar_10: 0.072,
          relative_humidity: 47,
          pressure_msl: 1011.8
        }
      }.to_json, headers: { "Content-Type" => "application/json" })

    weather = @client.current_weather

    assert_equal Time.parse("2026-05-04T15:00:00+00:00"), weather.fetch(:timestamp)
    assert_equal 303711, weather.fetch(:source_id)
    assert_in_delta 16.2, weather.fetch(:temperature)
    assert_equal "cloudy", weather.fetch(:icon)
    assert_equal "day", weather.fetch(:daytime)
    assert_in_delta 13.7, weather.fetch(:wind_speed)
    assert_in_delta 0.0, weather.fetch(:precipitation)
    assert_in_delta 0.072, weather.fetch(:solar)
  end

  def test_fetches_hourly_weather_for_date
    stub_request(:get, "https://api.brightsky.dev/weather")
      .with(query: { lat: "52.52", lon: "13.405", date: "2026-05-04" })
      .to_return(status: 200, body: {
        weather: [
          {
            timestamp: "2026-05-04T00:00:00+02:00",
            source_id: 7003,
            precipitation: 0,
            pressure_msl: 1011.6,
            sunshine: nil,
            temperature: 16.2,
            wind_direction: 210,
            wind_speed: 9.7,
            cloud_cover: 100,
            dew_point: 12.7,
            relative_humidity: 80,
            visibility: 42600,
            wind_gust_direction: 220,
            wind_gust_speed: 18.7,
            condition: "dry",
            precipitation_probability: nil,
            precipitation_probability_6h: nil,
            solar: nil,
            icon: "cloudy"
          }
        ]
      }.to_json, headers: { "Content-Type" => "application/json" })

    rows = @client.weather_for_date(Date.new(2026, 5, 4))

    assert_equal 1, rows.length
    assert_equal 7003, rows.first.fetch(:source_id)
    assert_equal "cloudy", rows.first.fetch(:icon)
    assert_equal "night", rows.first.fetch(:daytime)
  end

  def test_weather_for_date_returns_range_end_for_404
    stub_request(:get, "https://api.brightsky.dev/weather")
      .with(query: { lat: "52.52", lon: "13.405", date: "2026-05-15" })
      .to_return(status: 404, body: "{}")

    assert_equal :range_end, @client.weather_for_date(Date.new(2026, 5, 15))
  end
end
