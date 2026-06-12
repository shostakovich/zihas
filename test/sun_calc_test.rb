require "test_helper"
require "sun_calc"

class SunCalcTest < Minitest::Test
  BERLIN_LAT = 52.52
  BERLIN_LON = 13.405
  BERLIN_TZ  = "Europe/Berlin"

  # Reference times come from the NOAA Solar Calculator. The single-pass
  # algorithm in SunCalc is accurate to a few minutes at mid latitudes —
  # we allow ±15 min tolerance to keep the suite robust across years.
  TOLERANCE_SECONDS = 15 * 60

  def test_summer_solstice_berlin
    sunrise = SunCalc.sunrise(date: Date.new(2026, 6, 21), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)
    sunset  = SunCalc.sunset(date:  Date.new(2026, 6, 21), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)

    # 04:43 CEST = 02:43 UTC
    assert_in_delta Time.utc(2026, 6, 21, 2, 43).to_i, sunrise.to_i, TOLERANCE_SECONDS
    # 21:33 CEST = 19:33 UTC
    assert_in_delta Time.utc(2026, 6, 21, 19, 33).to_i, sunset.to_i, TOLERANCE_SECONDS
  end

  def test_winter_solstice_berlin
    sunrise = SunCalc.sunrise(date: Date.new(2025, 12, 21), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)
    sunset  = SunCalc.sunset(date:  Date.new(2025, 12, 21), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)

    # 08:15 CET = 07:15 UTC
    assert_in_delta Time.utc(2025, 12, 21, 7, 15).to_i, sunrise.to_i, TOLERANCE_SECONDS
    # 15:54 CET = 14:54 UTC
    assert_in_delta Time.utc(2025, 12, 21, 14, 54).to_i, sunset.to_i, TOLERANCE_SECONDS
  end

  def test_daytime_classification
    # Noon in Berlin → day
    assert SunCalc.daytime?(timestamp: Time.utc(2026, 6, 21, 10), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)
    # Midnight UTC = 02:00 CEST → night
    refute SunCalc.daytime?(timestamp: Time.utc(2026, 6, 21, 0),  lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)
  end

  def test_winter_evening_is_night_in_berlin
    # 17:00 CET = 16:00 UTC, well after sunset on Dec 21
    refute SunCalc.daytime?(timestamp: Time.utc(2025, 12, 21, 16), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)
  end

  def test_summer_evening_is_still_day_in_berlin
    # 20:30 CEST = 18:30 UTC, before sunset on Jun 21 (~21:33 CEST)
    assert SunCalc.daytime?(timestamp: Time.utc(2026, 6, 21, 18, 30), lat: BERLIN_LAT, lon: BERLIN_LON, timezone: BERLIN_TZ)
  end

  def test_polar_day_returns_true_around_the_clock
    # Above the Arctic Circle on June 21 the sun never sets.
    [ 0, 6, 12, 18, 23 ].each do |hour|
      assert SunCalc.daytime?(timestamp: Time.utc(2026, 6, 21, hour), lat: 78.0, lon: 15.0, timezone: "UTC"),
        "expected polar day at hour #{hour}"
    end
  end

  def test_polar_night_returns_false_around_the_clock
    # Above the Arctic Circle on December 21 the sun never rises.
    [ 0, 6, 12, 18, 23 ].each do |hour|
      refute SunCalc.daytime?(timestamp: Time.utc(2025, 12, 21, hour), lat: 78.0, lon: 15.0, timezone: "UTC"),
        "expected polar night at hour #{hour}"
    end
  end
end
