require "date"
require "tzinfo"

# Sunrise/sunset for a given date and location, computed locally with the
# NOAA general solar position algorithm
# (https://gml.noaa.gov/grad/solcalc/solareqns.PDF). Single-pass at solar noon,
# accurate to a few minutes at mid latitudes — sufficient for deciding whether
# a weather record falls into "day" or "night".
module SunCalc
  ZENITH_DEG = 90.833

  module_function

  def sunrise(date:, lat:, lon:, timezone:)
    event_time(date, lat, lon, timezone, :sunrise)
  end

  def sunset(date:, lat:, lon:, timezone:)
    event_time(date, lat, lon, timezone, :sunset)
  end

  def daytime?(timestamp:, lat:, lon:, timezone:)
    tz = TZInfo::Timezone.get(timezone)
    local_date = tz.utc_to_local(timestamp.to_time.utc).to_date
    cos_ha = cos_hour_angle(local_date, lat)

    return true  if cos_ha < -1.0 # polar day
    return false if cos_ha >  1.0 # polar night

    sr = event_time(local_date, lat, lon, timezone, :sunrise)
    ss = event_time(local_date, lat, lon, timezone, :sunset)
    timestamp >= sr && timestamp < ss
  end

  def event_time(date, lat, lon, timezone, event)
    cos_ha = cos_hour_angle(date, lat)
    return nil if cos_ha.abs > 1.0

    minutes = solar_event_minutes_utc(date, lon, cos_ha, event)
    Time.utc(date.year, date.month, date.day, 0, 0, 0) + minutes * 60
  end

  # NOAA single-pass formula evaluated at solar noon (hour = 12 UTC).
  def solar_terms(date)
    n = date.yday
    gamma = 2 * Math::PI / 365.0 * (n - 1)

    eqtime = 229.18 * (
      0.000075 +
      0.001868 * Math.cos(gamma) -
      0.032077 * Math.sin(gamma) -
      0.014615 * Math.cos(2 * gamma) -
      0.040849 * Math.sin(2 * gamma)
    )

    decl =
      0.006918 -
      0.399912 * Math.cos(gamma) +
      0.070257 * Math.sin(gamma) -
      0.006758 * Math.cos(2 * gamma) +
      0.000907 * Math.sin(2 * gamma) -
      0.002697 * Math.cos(3 * gamma) +
      0.00148  * Math.sin(3 * gamma)

    [ eqtime, decl ]
  end

  def cos_hour_angle(date, lat)
    _, decl = solar_terms(date)
    lat_rad = lat * Math::PI / 180.0
    zenith_rad = ZENITH_DEG * Math::PI / 180.0
    (Math.cos(zenith_rad) - Math.sin(lat_rad) * Math.sin(decl)) /
      (Math.cos(lat_rad) * Math.cos(decl))
  end

  def solar_event_minutes_utc(date, lon, cos_ha, event)
    eqtime, _ = solar_terms(date)
    ha_deg = Math.acos(cos_ha) * 180.0 / Math::PI
    case event
    when :sunrise then 720 - 4 * (lon + ha_deg) - eqtime
    when :sunset  then 720 - 4 * (lon - ha_deg) - eqtime
    end
  end
end
