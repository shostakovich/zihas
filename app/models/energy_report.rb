require "date"
require "tzinfo"
require "savings_calculator"

class EnergyReport
  Report = Struct.new(
    :start_date,
    :end_date,
    :selected_date,
    :preset,
    :summary,
    :daily_points,
    :producer_ranking,
    :consumer_ranking,
    :detail_start_date,
    :detail_end_date,
    :chart_payload,
    :messages,
    keyword_init: true
  ) do
    def empty?
      daily_points.empty?
    end
  end

  DEFAULT_PRESET = "last_7"
  PRESET_DAYS = {
    "last_7" => 7,
    "last_30" => 30
  }.freeze

  def initialize(params:, plugs:, timezone: "UTC", electricity_price_eur_per_kwh: 0.32, weather_loader: nil)
    @params = params.to_h.with_indifferent_access
    @plugs = plugs
    @plug_by_id = plugs.index_by(&:id)
    @timezone = TZInfo::Timezone.get(timezone)
    @savings_calculator = SavingsCalculator.new(price_eur_per_kwh: electricity_price_eur_per_kwh)
    @store = Store.new
    @chart_builder = ChartBuilder.new(plugs: plugs, timezone: @timezone, store: @store, weather_loader: weather_loader)
    @messages = []
  end

  def build
    latest = @store.latest_aggregate_date
    return empty_report(Date.current, Date.current) if latest.nil?

    range = resolve_range(latest)
    rows = @store.daily_rows(range.fetch(:start_date), range.fetch(:end_date))
    summaries = @store.daily_summaries(range.fetch(:start_date), range.fetch(:end_date))
    daily_points = build_daily_points(summaries, range.fetch(:start_date), range.fetch(:end_date))
    summary = summarize(daily_points)
    selected_date = resolve_selected_date(range.fetch(:start_date), range.fetch(:end_date))
    detail_range = resolve_detail_range(range.fetch(:start_date), range.fetch(:end_date))

    Report.new(
      start_date: range.fetch(:start_date),
      end_date: range.fetch(:end_date),
      selected_date: selected_date,
      preset: range.fetch(:preset),
      summary: summary,
      daily_points: daily_points,
      producer_ranking: ranking(rows, :producer),
      consumer_ranking: ranking(rows, :consumer),
      detail_start_date: detail_range.fetch(:start_date),
      detail_end_date: detail_range.fetch(:end_date),
      chart_payload: @chart_builder.payload(daily_points: daily_points, rows: rows, range: range, detail_range: detail_range),
      messages: @messages
    )
  end

  private

  def empty_report(start_date, end_date)
    Report.new(
      start_date: start_date,
      end_date: end_date,
      selected_date: start_date,
      preset: DEFAULT_PRESET,
      summary: empty_summary,
      daily_points: [],
      producer_ranking: [],
      consumer_ranking: [],
      detail_start_date: start_date,
      detail_end_date: end_date,
      chart_payload: {
        daily: { labels: [], produced_kwh: [], consumed_kwh: [], balance_kwh: [], consumer_series: [], ratios: [] },
        detail: { labels: [], series: [] }
      },
      messages: @messages
    )
  end

  def resolve_range(latest)
    if custom_range_requested?
      start_date = parse_date(@params[:start_date])
      end_date = parse_date(@params[:end_date])

      if start_date && end_date && start_date <= end_date
        end_date = [ end_date, latest ].min
        start_date = [ start_date, end_date ].min
        return { start_date: start_date, end_date: end_date, preset: "custom" }
      end

      @messages << "Der Datumsbereich war ungueltig und wurde auf die letzten 7 Tage zurueckgesetzt."
    end

    preset = PRESET_DAYS.key?(@params[:preset]) ? @params[:preset] : DEFAULT_PRESET
    days = PRESET_DAYS.fetch(preset)
    { start_date: latest - (days - 1), end_date: latest, preset: preset }
  end

  def custom_range_requested?
    @params[:start_date].present? || @params[:end_date].present?
  end

  def parse_date(value)
    return nil if value.blank?

    Date.iso8601(value)
  rescue ArgumentError
    nil
  end

  def resolve_selected_date(start_date, end_date)
    parsed = parse_date(@params[:selected_date])
    return parsed if parsed && parsed >= start_date && parsed <= end_date

    end_date
  end

  def resolve_detail_range(start_date, end_date)
    { start_date: start_date, end_date: end_date }
  end

  def build_daily_points(summaries, start_date, end_date)
    (start_date..end_date).map do |date|
      date_s = date.to_s
      summary = summaries[date_s]
      if summary
        {
          date: date_s,
          produced_kwh:      kwh(summary.produced_wh),
          consumed_kwh:      kwh(summary.consumed_wh),
          self_consumed_kwh: kwh(summary.self_consumed_wh),
          balance_kwh:       kwh(summary.produced_wh - summary.consumed_wh),
          covered:           true
        }
      else
        {
          date: date_s,
          produced_kwh:      0.0,
          consumed_kwh:      0.0,
          self_consumed_kwh: 0.0,
          balance_kwh:       0.0,
          covered:           false
        }
      end
    end
  end

  def summarize(daily_points)
    covered_points = daily_points.select { |p| p.fetch(:covered) }
    produced       = covered_points.sum { |p| p.fetch(:produced_kwh) }
    consumed       = covered_points.sum { |p| p.fetch(:consumed_kwh) }
    self_consumed  = covered_points.sum { |p| p.fetch(:self_consumed_kwh) }
    days = covered_points.length

    {
      produced_kwh:           produced.round(3),
      consumed_kwh:           consumed.round(3),
      self_consumed_kwh:      self_consumed.round(3),
      savings_eur:            @savings_calculator.savings_eur(produced * 1000.0).round(2),
      balance_kwh:            (produced - consumed).round(3),
      avg_produced_kwh:       average_kwh(produced, days),
      avg_consumed_kwh:       average_kwh(consumed, days),
      autarky_ratio:          ratio(self_consumed, consumed),
      self_consumption_ratio: ratio(self_consumed, produced)
    }
  end

  def ratio(numerator, denominator)
    return 0.0 if denominator.nil? || denominator.zero?
    (numerator.to_f / denominator).round(4)
  end

  def empty_summary
    {
      produced_kwh:           0.0,
      consumed_kwh:           0.0,
      self_consumed_kwh:      0.0,
      savings_eur:            0.0,
      balance_kwh:            0.0,
      avg_produced_kwh:       0.0,
      avg_consumed_kwh:       0.0,
      autarky_ratio:          0.0,
      self_consumption_ratio: 0.0
    }
  end

  def average_kwh(total_kwh, days)
    return 0.0 if days.zero?

    (total_kwh / days).round(3)
  end

  def ranking(rows, role)
    rows
      .select { |row| plug_role(row.plug_id) == role }
      .group_by(&:plug_id)
      .map do |plug_id, plug_rows|
        plug = @plug_by_id.fetch(plug_id)
        {
          plug_id: plug_id,
          name: plug.name,
          role: role.to_s,
          kwh: kwh(plug_rows.sum(&:energy_wh))
        }
      end
      .sort_by { |row| -row.fetch(:kwh) }
  end

  def plug_role(plug_id)
    @plug_by_id[plug_id]&.role
  end

  def kwh(wh)
    (wh.to_f / 1000.0).round(3)
  end
end
