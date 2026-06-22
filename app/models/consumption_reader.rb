# Reads current measured household consumption from Shelly/Fritz samples
# and computes the export-safe lower bound (guaranteed_floor_w).
class ConsumptionReader
  FLOOR_WINDOW_S         = 24 * 60 * 60
  MEDIAN_WINDOW_S        = 30 * 60
  BUCKET_S               = 300
  NIGHT_BASE_DAYS        = 7
  NIGHT_EDGE_EXCLUSION_S = 60 * 60

  def initialize(plugs:, now: Time.now, stale_after_s: 120)
    @consumer_ids  = plugs.select { |p| p.role == :consumer }.map(&:id)
    @now           = now
    @stale_after_s = stale_after_s
  end

  # Sum of the latest fresh apower_w across consumer plugs, or nil when no
  # consumer plug has a fresh sample. nil (unknown) is deliberately distinct
  # from 0.0 (measured zero) so the controller can fall back to the floor only
  # when live data is genuinely missing, never overriding a real low reading.
  def current_consumption_w
    return nil if @consumer_ids.empty?
    now_ts = @now.to_i
    fresh = Sample
      .where(plug_id: @consumer_ids)
      .where("(plug_id, ts) IN (SELECT plug_id, MAX(ts) FROM samples WHERE plug_id IN (?) GROUP BY plug_id)", @consumer_ids)
      .select { |s| (now_ts - s.ts) <= @stale_after_s }
    return nil if fresh.empty?
    fresh.sum(&:apower_w)
  end

  # Minimum total 5-min consumption over the last 24h. Computed from raw
  # samples because samples_5min is only built daily by the Aggregator.
  def guaranteed_floor_w
    return 0.0 if @consumer_ids.empty?

    totals = Hash.new(0.0)
    bucket_avg_rows(@now.to_i - FLOOR_WINDOW_S).each { |r| totals[r.bucket_ts] += r.avg_w.to_f }
    totals.empty? ? 0.0 : totals.values.min
  end

  # Median total 5-min consumption over the last 30 minutes. This caps short
  # live-load spikes while still letting current_consumption_w clamp downward
  # immediately after a load drop.
  def median_consumption_w
    return nil if @consumer_ids.empty?

    totals = Hash.new(0.0)
    bucket_avg_rows(@now.to_i - MEDIAN_WINDOW_S).each { |r| totals[r.bucket_ts] += r.avg_w.to_f }
    values = totals.values.sort
    return nil if values.empty?

    mid = values.length / 2
    values.length.odd? ? values[mid].to_f : ((values[mid - 1] + values[mid]) / 2.0)
  end

  # P20 of recent-night 5-min consumption buckets — the controller's NIGHT_BASE
  # setpoint source. Falls back to fallback_w (or guaranteed_floor_w) when there
  # is no night data yet (e.g. fresh install).
  def night_base_w(lat:, lon:, timezone:, days: NIGHT_BASE_DAYS, fallback_w: nil)
    totals = night_bucket_totals(lat: lat, lon: lon, timezone: timezone, days: days.to_i)
    return fallback_w.to_f if totals.empty? && !fallback_w.nil?
    return guaranteed_floor_w if totals.empty?

    sorted = totals.sort
    sorted[((sorted.length - 1) * 0.20).floor].to_f
  end

  private

  def night_bucket_totals(lat:, lon:, timezone:, days:)
    return [] if @consumer_ids.empty?
    ranges = night_ranges(lat: lat, lon: lon, timezone: timezone, days: days)
    return [] if ranges.empty?

    cutoff = ranges.map(&:first).min.to_i
    totals = Hash.new(0.0)
    bucket_avg_rows(cutoff).each do |row|
      bucket_ts = row.bucket_ts.to_i
      next unless ranges.any? { |start_at, end_at| bucket_ts >= start_at.to_i && bucket_ts < end_at.to_i }
      totals[bucket_ts] += row.avg_w.to_f
    end
    totals.values
  end

  # Per-plug, per-5-min-bucket average power since `cutoff` (unix seconds).
  # Shared by guaranteed_floor_w (24h min) and night_bucket_totals (night P20).
  def bucket_avg_rows(cutoff)
    Sample
      .where(plug_id: @consumer_ids)
      .where("ts >= ?", cutoff)
      .group("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S}"))
      .select("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S} AS bucket_ts"), Arel.sql("AVG(apower_w) AS avg_w"))
  end

  def night_ranges(lat:, lon:, timezone:, days:)
    tz = TZInfo::Timezone.get(timezone)
    today = tz.utc_to_local(@now.to_time.utc).to_date
    (1..days).filter_map do |offset|
      sunset_date  = today - offset
      sunrise_date = sunset_date + 1
      sunset  = SunCalc.sunset(date: sunset_date, lat: lat, lon: lon, timezone: timezone)
      sunrise = SunCalc.sunrise(date: sunrise_date, lat: lat, lon: lon, timezone: timezone)
      next if sunset.nil? || sunrise.nil?
      [ sunset + NIGHT_EDGE_EXCLUSION_S, sunrise - NIGHT_EDGE_EXCLUSION_S ]
    end
  end
end
