class EnergySummary
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
    [start_utc, start_utc + 86_400, local_today]
  end

  def producer_ids
    @config.plugs.select { |p| p.role == :producer }.map(&:id)
  end

  def consumer_ids
    @config.plugs.select { |p| p.role == :consumer }.map(&:id)
  end

  def energy_delta_wh(plug_ids, start_ts, end_ts)
    return 0.0 if plug_ids.empty?
    rows = Sample.where(plug_id: plug_ids, ts: start_ts..(end_ts - 1))
                 .group(:plug_id)
                 .select("plug_id, MAX(aenergy_wh) - MIN(aenergy_wh) AS delta")
    rows.sum { |r| r.delta || 0 }.to_f
  end
end
