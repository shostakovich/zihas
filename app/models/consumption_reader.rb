# Reads current measured household consumption from Shelly/Fritz samples
# and computes the export-safe lower bound (guaranteed_floor_w).
class ConsumptionReader
  FLOOR_WINDOW_S = 24 * 60 * 60
  BUCKET_S       = 300

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
    cutoff = @now.to_i - FLOOR_WINDOW_S
    rows = Sample
      .where(plug_id: @consumer_ids)
      .where("ts >= ?", cutoff)
      .group("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S}"))
      .select("plug_id", Arel.sql("(ts / #{BUCKET_S}) * #{BUCKET_S} AS bucket_ts"), Arel.sql("AVG(apower_w) AS avg_w"))

    totals = Hash.new(0.0)
    rows.each { |r| totals[r.bucket_ts] += r.avg_w.to_f }
    totals.empty? ? 0.0 : totals.values.min
  end
end
