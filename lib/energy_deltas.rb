# Shared CTE for plausibility-capped energy deltas from cumulative counters.
#
# Emits `WITH window_samples AS (...), deltas AS (...)` over `samples`,
# exposing per-row `delta_wh` (plus plug_id/ts/apower_w). Callers append
# their own SELECT. Bind order: [plug_ids?, start_ts, end_ts].
module EnergyDeltas
  # 20 kW is above any realistic single-circuit load, while counter glitches
  # can imply megawatts for a few seconds.
  MAX_PLAUSIBLE_W = 20_000

  module_function

  def cte(filter_plug_ids: false)
    plug_filter = filter_plug_ids ? "plug_id IN (?) AND" : ""
    <<~SQL
      WITH window_samples AS (
        SELECT plug_id, ts, apower_w, aenergy_wh,
               LAG(ts)         OVER (PARTITION BY plug_id ORDER BY ts) AS prev_ts,
               LAG(aenergy_wh) OVER (PARTITION BY plug_id ORDER BY ts) AS prev_wh
          FROM samples
         WHERE #{plug_filter} ts >= ? AND ts < ?
      ),
      deltas AS (
        SELECT plug_id, ts, apower_w,
               CASE
                 WHEN prev_wh IS NULL      THEN 0
                 WHEN aenergy_wh < prev_wh THEN 0
                 WHEN aenergy_wh - prev_wh
                      > #{MAX_PLAUSIBLE_W}.0 * (ts - prev_ts) / 3600.0 THEN 0
                 ELSE aenergy_wh - prev_wh
               END AS delta_wh
          FROM window_samples
      )
    SQL
  end
end