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

  BERLIN = { lat: 52.52, lon: 13.405, timezone: "Europe/Berlin" }.freeze

  def test_derives_daytime_from_icon_suffix
    assert_equal "day", WeatherIcon.daytime_for(icon: "clear-day", timestamp: Time.utc(2026, 5, 4, 22), **BERLIN)
    assert_equal "night", WeatherIcon.daytime_for(icon: "clear-night", timestamp: Time.utc(2026, 5, 4, 12), **BERLIN)
  end

  def test_derives_daytime_from_sun_position_for_neutral_icon
    # 12:00 CEST is well after sunrise, before sunset → day
    assert_equal "day", WeatherIcon.daytime_for(icon: "rain", timestamp: Time.utc(2026, 5, 4, 10), **BERLIN)
    # 00:00 CEST is well after sunset → night
    assert_equal "night", WeatherIcon.daytime_for(icon: "rain", timestamp: Time.utc(2026, 5, 4, 22), **BERLIN)
  end

  def test_uses_real_sunrise_not_fixed_window
    # Berlin around the winter solstice: sunset ~16:30 CEST, so 18:00 CEST is night
    # even though the previously hardcoded 6–20 window would have flagged it as day.
    assert_equal "night", WeatherIcon.daytime_for(icon: "cloudy", timestamp: Time.utc(2025, 12, 21, 17), **BERLIN)
    # And around the summer solstice: 21:00 CEST (= 19:00 UTC) is still daylight.
    assert_equal "day", WeatherIcon.daytime_for(icon: "cloudy", timestamp: Time.utc(2026, 6, 21, 19), **BERLIN)
  end
end
