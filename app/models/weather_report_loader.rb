require "tzinfo"

# Loads weather context for the energy report. Operates on `historic`
# WeatherRecords for a given lat/lon and exposes per-day and per-hour
# aggregates suited for chart overlays.
#
#   loader = WeatherReportLoader.new(lat: 48.15, lon: 11.26, timezone: "Europe/Berlin")
#   loader.daily(start_date, end_date)   # => { "2026-05-01" => { solar_kwh_per_m2:, asset_name:, alt: }, ... }
#   loader.hourly(start_date, end_date)  # => [{ ts:, solar_w_per_m2:, asset_name:, alt: }, ...]
class WeatherReportLoader
  def self.from_app_config(app_config)
    weather = app_config.weather
    return nil if weather.nil? || weather.lat.nil? || weather.lon.nil?

    new(lat: weather.lat, lon: weather.lon, timezone: app_config.timezone || "UTC")
  end

  def initialize(lat:, lon:, timezone: "UTC")
    @lat = lat
    @lon = lon
    @tz = TZInfo::Timezone.get(timezone)
  end

  # Returns a Hash keyed by ISO date string with per-day weather summary.
  # Days without any historic records are omitted.
  def daily(start_date, end_date)
    records = historic_records_in_range(start_date, end_date)
    grouped = records.group_by { |r| local_date(r.timestamp) }

    grouped.each_with_object({}) do |(date, day_records), out|
      next if date < start_date || date > end_date

      out[date.to_s] = {
        solar_kwh_per_m2: day_solar_kwh(day_records),
        asset_name:       day_asset_name(day_records),
        alt:              day_alt(day_records)
      }
    end
  end

  # Returns an Array of hourly points (one per local hour with data) for
  # the inclusive date range. Each point: { ts:, solar_w_per_m2:,
  # asset_name:, alt: }. `ts` is a UTC unix timestamp at the start of the
  # source's hour bucket.
  def hourly(start_date, end_date)
    records = historic_records_in_range(start_date, end_date)
    records.map do |r|
      {
        ts:              r.timestamp.to_i,
        solar_w_per_m2:  r.solar_w_per_m2,
        asset_name:      r.asset_name,
        alt:             r.icon.to_s
      }
    end
  end

  private

  def historic_records_in_range(start_date, end_date)
    start_ts = local_midnight_utc(start_date)
    end_ts   = local_midnight_utc(end_date + 1)
    WeatherRecord.historic
                 .for_location(@lat, @lon)
                 .where(timestamp: start_ts...end_ts)
                 .order(:timestamp)
                 .to_a
  end

  def day_solar_kwh(records)
    values = records.filter_map(&:solar)
    return nil if values.empty?
    # `historic` solar is kWh/m² accumulated per 60-min source period —
    # summing yields the daily total in kWh/m².
    values.sum.round(3)
  end

  def day_asset_name(records)
    day_segment(records).asset_name
  end

  def day_alt(records)
    day_segment(records).dominant_icon
  end

  def day_segment(records)
    daytime_records = records.select { |r| r.daytime == "day" }
    pool = daytime_records.any? ? daytime_records : records
    WeatherSegment.new(label: "day", hour_range: 0..23, records: pool)
  end

  def local_date(timestamp)
    @tz.utc_to_local(timestamp.utc).to_date
  end

  def local_midnight_utc(date)
    local_midnight = Time.new(date.year, date.month, date.day, 0, 0, 0)
    @tz.local_to_utc(local_midnight)
  end
end
