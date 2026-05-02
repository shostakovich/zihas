class EnergySummary
  # Plausible per-sample power ceiling used to cap energy deltas. 20 kW is
  # above any realistic single-circuit load, while counter glitches can imply
  # megawatts for a few seconds.
  MAX_PLAUSIBLE_W = 20_000

  attr_reader :produced_wh, :consumed_wh, :savings_eur, :date

  def initialize(config:)
    @config     = config
    @tz         = TZInfo::Timezone.get(config.timezone)
    @calculator = SavingsCalculator.new(price_eur_per_kwh: config.electricity_price_eur_per_kwh)
  end

  def compute_today
    start_ts, end_ts, today = today_bounds_utc
    @produced_wh = energy_delta_wh(producer_ids, start_ts, end_ts)
    @consumed_wh = energy_delta_wh(consumer_ids, start_ts, end_ts)
    @savings_eur = @calculator.savings_eur(@produced_wh)
    @date        = today.to_s
    self
  end

  private

  def today_bounds_utc
    now_utc     = Time.now.utc
    local_today = @tz.utc_to_local(now_utc).to_date
    midnight    = Time.new(local_today.year, local_today.month, local_today.day, 0, 0, 0)
    start_utc   = @tz.local_to_utc(midnight).to_i
    [ start_utc, start_utc + 86_400, local_today ]
  end

  def producer_ids
    @config.plugs.select { |p| p.role == :producer }.map(&:id)
  end

  def consumer_ids
    @config.plugs.select { |p| p.role == :consumer }.map(&:id)
  end

  def energy_delta_wh(plug_ids, start_ts, end_ts)
    return 0.0 if plug_ids.empty?

    sql = <<~SQL
      WITH window_samples AS (
        SELECT plug_id, ts, aenergy_wh,
               LAG(ts)         OVER (PARTITION BY plug_id ORDER BY ts) AS prev_ts,
               LAG(aenergy_wh) OVER (PARTITION BY plug_id ORDER BY ts) AS prev_wh
          FROM samples
         WHERE plug_id IN (?) AND ts >= ? AND ts < ?
      ),
      deltas AS (
        SELECT plug_id,
               CASE
                 WHEN prev_wh IS NULL      THEN 0
                 WHEN aenergy_wh < prev_wh THEN 0
                 WHEN aenergy_wh - prev_wh
                      > #{MAX_PLAUSIBLE_W}.0 * (ts - prev_ts) / 3600.0 THEN 0
                 ELSE aenergy_wh - prev_wh
               END AS delta_wh
          FROM window_samples
      )
      SELECT plug_id, SUM(delta_wh) AS delta
        FROM deltas
       GROUP BY plug_id
    SQL

    rows = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([ sql, plug_ids, start_ts, end_ts ])
    )
    rows.sum { |row| row["delta"] || 0 }.to_f
  end
end
