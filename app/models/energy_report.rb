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

  def initialize(params:, plugs:, timezone: "UTC", electricity_price_eur_per_kwh: 0.32)
    @params = params.to_h.with_indifferent_access
    @plugs = plugs
    @plug_by_id = plugs.index_by(&:id)
    @timezone = TZInfo::Timezone.get(timezone)
    @savings_calculator = SavingsCalculator.new(price_eur_per_kwh: electricity_price_eur_per_kwh)
    @messages = []
  end

  def build
    latest = latest_aggregate_date
    return empty_report(Date.current, Date.current) if latest.nil?

    range = resolve_range(latest)
    rows = daily_rows(range.fetch(:start_date), range.fetch(:end_date))
    daily_points = build_daily_points(rows, range.fetch(:start_date), range.fetch(:end_date))
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
      chart_payload: {
        daily: daily_chart_payload(daily_points),
        detail: detail_chart_payload(rows, detail_range.fetch(:start_date), detail_range.fetch(:end_date))
      },
      messages: @messages
    )
  end

  private

  def latest_aggregate_date
    value = DailyTotal.maximum(:date)
    value.present? ? Date.iso8601(value) : nil
  end

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
        daily: { labels: [], produced_kwh: [], consumed_kwh: [], balance_kwh: [] },
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

  def daily_rows(start_date, end_date)
    DailyTotal.where(date: start_date.to_s..end_date.to_s).to_a
  end

  def build_daily_points(rows, start_date, end_date)
    rows_by_date = rows.group_by(&:date)

    (start_date..end_date).map do |date|
      date_s = date.to_s
      day_rows = rows_by_date.fetch(date_s, [])
      produced_wh = sum_role(day_rows, :producer)
      consumed_wh = sum_role(day_rows, :consumer)

      {
        date: date_s,
        produced_kwh: kwh(produced_wh),
        consumed_kwh: kwh(consumed_wh),
        balance_kwh: kwh(produced_wh - consumed_wh)
      }
    end
  end

  def summarize(daily_points)
    produced = daily_points.sum { |point| point.fetch(:produced_kwh) }
    consumed = daily_points.sum { |point| point.fetch(:consumed_kwh) }
    days = daily_points.length

    {
      produced_kwh: produced.round(3),
      consumed_kwh: consumed.round(3),
      savings_eur: @savings_calculator.savings_eur(produced * 1000.0).round(2),
      balance_kwh: (produced - consumed).round(3),
      avg_produced_kwh: average_kwh(produced, days),
      avg_consumed_kwh: average_kwh(consumed, days)
    }
  end

  def empty_summary
    {
      produced_kwh: 0.0,
      consumed_kwh: 0.0,
      savings_eur: 0.0,
      balance_kwh: 0.0,
      avg_produced_kwh: 0.0,
      avg_consumed_kwh: 0.0
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

  def daily_chart_payload(daily_points)
    {
      labels: daily_points.map { |point| point.fetch(:date) },
      produced_kwh: daily_points.map { |point| point.fetch(:produced_kwh) },
      consumed_kwh: daily_points.map { |point| point.fetch(:consumed_kwh) },
      balance_kwh: daily_points.map { |point| point.fetch(:balance_kwh) },
      consumer_series: consumer_daily_series(daily_points.map { |point| point.fetch(:date) })
    }
  end

  def consumer_daily_series(labels)
    @plugs
      .select { |plug| plug.role == :consumer }
      .map do |plug|
        rows_by_date = DailyTotal.where(plug_id: plug.id, date: labels).index_by(&:date)
        {
          plug_id: plug.id,
          name: plug.name,
          data: labels.map do |date|
            row = rows_by_date[date]
            row ? kwh(row.energy_wh) : 0.0
          end
        }
      end
  end

  def detail_chart_payload(rows, start_date, end_date)
    return daily_power_detail_chart_payload(rows, start_date, end_date) if (end_date - start_date).to_i > 6

    sample_detail_chart_payload(start_date, end_date)
  end

  def sample_detail_chart_payload(start_date, end_date)
    start_ts = local_midnight_utc(start_date)
    end_ts = local_midnight_utc(end_date + 1)
    rows = Sample5min.where(bucket_ts: start_ts...end_ts).order(:bucket_ts).to_a
    timestamps = rows.map(&:bucket_ts).uniq.sort
    multi_day = start_date != end_date

    series = @plugs.map do |plug|
      plug_rows = rows.select { |row| row.plug_id == plug.id }
      points_by_ts = plug_rows.index_by(&:bucket_ts)
      {
        plug_id: plug.id,
        name: plug.name,
        role: plug.role.to_s,
        data: timestamps.map do |ts|
          row = points_by_ts[ts]
          row ? watt_value(row.avg_power_w, plug.role) : nil
        end
      }
    end.select { |series_row| series_row.fetch(:data).any?(&:present?) }

    {
      chart_type: "line",
      labels: timestamps.map { |ts| detail_label(ts, multi_day) },
      series: series
    }
  end

  def daily_power_detail_chart_payload(rows, start_date, end_date)
    rows_by_plug_and_date = rows.group_by { |row| [ row.plug_id, row.date ] }
    dates = (start_date..end_date).to_a

    series = @plugs.map do |plug|
      {
        plug_id: plug.id,
        name: plug.name,
        role: plug.role.to_s,
        data: dates.map do |date|
          row = rows_by_plug_and_date[[ plug.id, date.to_s ]]&.first
          row ? average_power_w(row.energy_wh, plug.role) : nil
        end
      }
    end.select { |series_row| series_row.fetch(:data).any?(&:present?) }

    {
      chart_type: "bar",
      labels: dates.map { |date| date.strftime("%d.%m") },
      series: series
    }
  end

  def local_midnight_utc(date)
    local_midnight = Time.new(date.year, date.month, date.day, 0, 0, 0)
    @timezone.local_to_utc(local_midnight).to_i
  end

  def detail_label(ts, multi_day)
    local_time = @timezone.utc_to_local(Time.at(ts).utc)
    local_time.strftime(multi_day ? "%d.%m %H:%M" : "%H:%M")
  end

  def sum_role(rows, role)
    rows.select { |row| plug_role(row.plug_id) == role }.sum(&:energy_wh)
  end

  def plug_role(plug_id)
    @plug_by_id[plug_id]&.role
  end

  def watt_value(value, role)
    role == :producer ? value.abs.round(1) : value.round(1)
  end

  def average_power_w(energy_wh, role)
    watt_value(energy_wh.to_f / 24.0, role)
  end

  def kwh(wh)
    (wh.to_f / 1000.0).round(3)
  end
end
