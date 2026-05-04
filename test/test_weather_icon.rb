require "test_helper"
require "weather_icon"

class WeatherIconTest < Minitest::Test
  def test_maps_bright_sky_day_and_night_icons
    assert_equal "weather_clear_day.webp", WeatherIcon.asset_name("clear-day", "day")
    assert_equal "weather_clear_night.webp", WeatherIcon.asset_name("clear-night", "night")
    assert_equal "weather_partly_cloudy_day.webp", WeatherIcon.asset_name("partly-cloudy-day", "day")
    assert_equal "weather_partly_cloudy_night.webp", WeatherIcon.asset_name("partly-cloudy-night", "night")
  end

  def test_maps_neutral_icons_with_daytime
    assert_equal "weather_rain_day.webp", WeatherIcon.asset_name("rain", "day")
    assert_equal "weather_rain_night.webp", WeatherIcon.asset_name("rain", "night")
  end

  def test_falls_back_for_unknown_icon
    assert_equal "weather_unknown_day.webp", WeatherIcon.asset_name("not-real", "day")
    assert_equal "weather_unknown_night.webp", WeatherIcon.asset_name(nil, "night")
  end

  def test_derives_daytime_from_icon_suffix
    assert_equal "day", WeatherIcon.daytime_for(icon: "clear-day", timestamp: Time.utc(2026, 5, 4, 22), timezone: "Europe/Berlin")
    assert_equal "night", WeatherIcon.daytime_for(icon: "clear-night", timestamp: Time.utc(2026, 5, 4, 12), timezone: "Europe/Berlin")
  end

  def test_derives_daytime_from_local_hour_for_neutral_icon
    assert_equal "day", WeatherIcon.daytime_for(icon: "rain", timestamp: Time.utc(2026, 5, 4, 10), timezone: "Europe/Berlin")
    assert_equal "night", WeatherIcon.daytime_for(icon: "rain", timestamp: Time.utc(2026, 5, 4, 22), timezone: "Europe/Berlin")
  end
end
