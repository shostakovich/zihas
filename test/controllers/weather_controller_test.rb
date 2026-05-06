require "test_helper"

class WeatherControllerTest < ActionDispatch::IntegrationTest
  setup do
    WeatherRecord.delete_all
    # Tests reference 2026-05-04..06; freeze "now" so the controller's
    # Time.zone.today filter is stable regardless of the wall clock.
    travel_to Time.zone.local(2026, 5, 4, 12, 0)
  end

  teardown { travel_back }

  test "renders empty state without weather data" do
    get "/weather"

    assert_response :success
    assert_select ".empty-state", text: /Noch keine Wetterdaten/
  end

  test "renders current weather today and next days" do
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "day", icon: "cloudy", temperature: 16.2, condition: "dry", wind_speed: 9.7, relative_humidity: 80, cloud_cover: 100, precipitation: 0, pressure_msl: 1011.6)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-04 13:00"), daytime: "day", icon: "partly-cloudy-day", temperature: 18, precipitation: 0, solar: 0.32, wind_speed: 11)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405, timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day", icon: "clear-day", temperature: 20, precipitation_probability: 4, solar: 0.48, wind_speed: 12)

    get "/weather"

    assert_response :success
    assert_select ".weather-current"
    assert_select ".weather-current", text: /16,2/
    assert_select ".weather-hour-card", minimum: 1
    assert_select ".weather-day-card", minimum: 1
    assert_select ".weather-hour-card .weather-hour-solar", text: /320 W\/m²/
  end

  test "hourly card renders prominent solar value during the day" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-04 13:00"), daytime: "day",
      icon: "partly-cloudy-day", temperature: 18, precipitation: 0,
      solar: 0.32, wind_speed: 11)

    get "/weather"

    assert_select ".weather-hour-card .weather-hour-solar", text: /320 W\/m²/
  end

  test "today row hides hours before the current hour" do
    # Clock is frozen at 2026-05-04 12:00 in setup, so 09:00 must drop out.
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-04 09:00"), daytime: "day",
      icon: "clear-day", temperature: 12)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-04 13:00"), daytime: "day",
      icon: "partly-cloudy-day", temperature: 18, solar: 0.32)

    get "/weather"

    assert_select ".weather-hour-row .weather-hour-time", text: /09:00/, count: 0
    assert_select ".weather-hour-row .weather-hour-time", text: /13:00/, count: 1
  end

  test "today row extends through end of tomorrow" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 22:00"), daytime: "night",
      icon: "clear-night", temperature: 10)

    get "/weather"

    assert_select ".weather-hour-row .weather-hour-time", text: /22:00/, count: 1
  end

  test "hourly card renders Nacht at night and never a W/m² value" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-04 23:00"), daytime: "night",
      icon: "clear-night", temperature: 11, precipitation: 0,
      solar: 0, wind_speed: 5)

    get "/weather"

    assert_select ".weather-hour-card .weather-hour-solar", text: /Nacht/
    assert_select ".weather-hour-card .weather-hour-solar", text: /W\/m²/, count: 0
  end

  test "current weather card renders solar row with W/m² during the day" do
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-04 12:00"), daytime: "day",
      icon: "clear-day", temperature: 20.8, condition: "dry",
      wind_speed: 12, relative_humidity: 55, cloud_cover: 88,
      precipitation: 0, pressure_msl: 1012, solar: 0.072)

    get "/weather"

    assert_select ".weather-current-solar", text: /432 W\/m²/
  end

  test "current weather card renders Nacht in the solar row at night" do
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-04 23:00"), daytime: "night",
      icon: "clear-night", temperature: 12.0, condition: "dry",
      wind_speed: 4, relative_humidity: 70, cloud_cover: 10,
      precipitation: 0, pressure_msl: 1015, solar: 200)

    get "/weather"

    assert_select ".weather-current-solar", text: /Nacht/
    assert_select ".weather-current-solar", text: /W\/m²/, count: 0
  end

  test "day card renders weekday summary line and peak solar badge" do
    [
      { hour: 6, temp: 13, precip: 0.4, solar: 0.22 },
      { hour: 12, temp: 17, precip: 0.0, solar: 0.48 },
      { hour: 18, temp: 14, precip: 1.4, solar: 0.09 }
    ].each do |slot|
      WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
        timestamp: Time.zone.parse("2026-05-06 #{format('%02d', slot[:hour])}:00"),
        daytime: "day", icon: "partly-cloudy-day",
        temperature: slot[:temp], precipitation: slot[:precip], solar: slot[:solar])
    end

    get "/weather"

    assert_select ".weather-day-card .weather-day-summary", text: /13.*–.*17.*°C/
    assert_select ".weather-day-card .weather-day-summary", text: /Regen 1,8 mm/
    assert_select ".weather-day-card .weather-day-peak", text: /Spitze 480 W\/m²/
  end

  test "day card omits rain summary when total precipitation is zero" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-06 12:00"), daytime: "day",
      icon: "clear-day", temperature: 17, precipitation: 0)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-06 18:00"), daytime: "day",
      icon: "clear-day", temperature: 14, precipitation: nil)

    get "/weather"

    assert_select ".weather-day-card .weather-day-summary", text: /14.*–.*17.*°C/
    assert_select ".weather-day-card .weather-day-summary", text: /Regen/, count: 0
  end

  test "day card omits peak badge when every record has nil solar" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-06 12:00"), daytime: "day",
      icon: "cloudy", temperature: 12, precipitation: 0)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-06 18:00"), daytime: "day",
      icon: "cloudy", temperature: 11, precipitation: 0)

    get "/weather"

    assert_select ".weather-day-card .weather-day-peak", count: 0
  end

  test "day card renders Nacht in segment-solar when all hours are at night" do
    (0...6).each do |h|
      WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
        timestamp: Time.zone.parse("2026-05-06 #{format('%02d', h)}:00"),
        daytime: "night", icon: "clear-night", temperature: 10 + h)
    end
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-06 12:00"), daytime: "day",
      icon: "clear-day", temperature: 17, solar: 480)

    get "/weather"

    assert_select ".weather-segment-solar.is-night", text: /Nacht/
  end

  test "next-day card renders four segment tiles" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
      icon: "clear-day", temperature: 20)

    get "/weather"

    assert_select ".weather-day-card .weather-day-segments .weather-segment", count: 4
    assert_select ".weather-day-card .weather-segment-label", text: "Nacht"
    assert_select ".weather-day-card .weather-segment-label", text: "Vormittag"
    assert_select ".weather-day-card .weather-segment-label", text: "Nachmittag"
    assert_select ".weather-day-card .weather-segment-label", text: "Abend"
  end

  test "Nachmittag segment surfaces a 14:00 thunderstorm icon" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 12:00"), daytime: "day",
      icon: "clear-day", temperature: 22)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
      icon: "thunderstorm", temperature: 19)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 15:00"), daytime: "day",
      icon: "clear-day", temperature: 23)

    get "/weather"

    assert_select ".weather-segment", text: /Nachmittag/ do
      assert_select "img.weather-segment-icon[src*=?]", "weather_thunderstorm_day"
    end
  end

  test "segment without temperature data omits the range instead of showing 0 - 0" do
    # Vormittag (06–12) has a record with no temperature; the tile must not
    # render a fake "0 – 0°" range.
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 09:00"), daytime: "day",
      icon: "cloudy", temperature: nil)
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
      icon: "clear-day", temperature: 20)

    get "/weather"

    # Nachmittag has a temperature → range present.
    assert_select ".weather-segment", text: /Nachmittag/ do
      assert_select ".weather-segment-temp", text: /20.*–.*20°/
    end
    # Vormittag has no temperature → no .weather-segment-temp child rendered.
    assert_select ".weather-segment", text: /Vormittag/ do
      assert_select ".weather-segment-temp", count: 0
    end
  end

  test "next-day card emits hour rows hidden by default" do
    WeatherRecord.create!(kind: "forecast", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.parse("2026-05-05 14:00"), daytime: "day",
      icon: "clear-day", temperature: 20)

    get "/weather"

    assert_select ".weather-day-hours .weather-day-hour-row[hidden]", count: 4
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
