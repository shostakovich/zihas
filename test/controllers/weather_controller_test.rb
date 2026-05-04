require "test_helper"

class WeatherControllerTest < ActionDispatch::IntegrationTest
  setup { WeatherRecord.delete_all }

  test "renders empty state without weather data" do
    get "/weather"

    assert_response :success
    assert_select ".empty-state", text: /Noch keine Wetterdaten/
  end

  test "renders current weather today and next days" do
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "day", icon: "cloudy", temperature: 16.2, condition: "dry", wind_speed: 9.7, relative_humidity: 80, cloud_cover: 100, precipitation: 0, pressure_msl: 1011.6)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 13:00"), daytime: "day", icon: "partly-cloudy-day", temperature: 18, precipitation: 0, solar: 320, wind_speed: 11)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day", icon: "clear-day", temperature: 20, precipitation_probability: 4, solar: 480, wind_speed: 12)

    get "/weather"

    assert_response :success
    assert_select ".weather-current"
    assert_select ".weather-current", text: /16,2/
    assert_select ".weather-hour-card", minimum: 1
    assert_select ".weather-day-card", minimum: 1
    assert_select ".weather-solar", text: /320 W\/m²/
  end

  test "assigns future weather as WeatherDay instances with aggregates" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 09:00"), daytime: "day",
      icon: "partly-cloudy-day", temperature: 13, precipitation: 0.4, solar: 220)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day",
      icon: "clear-day", temperature: 17, precipitation: 1.4, solar: 480)

    get "/weather"

    future = controller.view_assigns["future_weather"]
    assert_equal 1, future.length
    assert_equal Date.new(2026, 5, 5), future.first.date
    assert_equal 13, future.first.temp_min
    assert_equal 17, future.first.temp_max
    assert_in_delta 1.8, future.first.precip_sum, 0.001
    assert_equal 480, future.first.solar_peak
  end
end
