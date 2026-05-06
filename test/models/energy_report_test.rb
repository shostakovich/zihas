require "test_helper"

class EnergyReportTest < ActiveSupport::TestCase
  setup do
    DailyTotal.delete_all
    Sample5min.delete_all
    DailyEnergySummary.delete_all

    @plugs = [
      ConfigLoader::PlugCfg.new(id: "pv", name: "Balkonkraftwerk", role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "desk", name: "Schreibtisch", role: :consumer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "washer", name: "Waschmaschine", role: :consumer, driver: :shelly, ain: nil)
    ]
  end

  test "defaults to the last seven fully aggregated days" do
    seed_daily("2026-04-01", pv: 1000, desk: 100, washer: 200)
    seed_daily("2026-04-02", pv: 1100, desk: 150, washer: 250)
    seed_daily("2026-04-03", pv: 1200, desk: 160, washer: 260)
    seed_daily("2026-04-04", pv: 1300, desk: 170, washer: 270)
    seed_daily("2026-04-05", pv: 1400, desk: 180, washer: 280)
    seed_daily("2026-04-06", pv: 1500, desk: 190, washer: 290)
    seed_daily("2026-04-07", pv: 1600, desk: 200, washer: 300)
    seed_daily("2026-04-08", pv: 1700, desk: 210, washer: 310)

    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert_equal Date.new(2026, 4, 2), report.start_date
    assert_equal Date.new(2026, 4, 8), report.end_date
    assert_equal "last_7", report.preset
    assert_equal 7, report.daily_points.length
    assert_in_delta 9.8, report.summary.fetch(:produced_kwh)
    assert_in_delta 3.22, report.summary.fetch(:consumed_kwh)
    assert_in_delta 3.14, report.summary.fetch(:savings_eur)
    assert_in_delta 6.58, report.summary.fetch(:balance_kwh)
    assert_in_delta 1.4, report.summary.fetch(:avg_produced_kwh)
    assert_in_delta 0.46, report.summary.fetch(:avg_consumed_kwh)
  end

  test "last thirty preset uses thirty fully aggregated days ending at latest day" do
    35.times do |i|
      date = Date.new(2026, 3, 1) + i
      seed_daily(date.to_s, pv: 1000, desk: 100, washer: 200)
    end

    report = EnergyReport.new(params: { preset: "last_30" }, plugs: @plugs).build

    assert_equal Date.new(2026, 3, 6), report.start_date
    assert_equal Date.new(2026, 4, 4), report.end_date
    assert_equal 30, report.daily_points.length
  end

  test "custom range is parsed and clamped to latest aggregate" do
    seed_daily("2026-04-10", pv: 1000, desk: 100, washer: 200)
    seed_daily("2026-04-11", pv: 2000, desk: 200, washer: 300)
    seed_daily("2026-04-12", pv: 3000, desk: 300, washer: 400)

    report = EnergyReport.new(
      params: { start_date: "2026-04-11", end_date: "2026-04-30" },
      plugs: @plugs
    ).build

    assert_equal Date.new(2026, 4, 11), report.start_date
    assert_equal Date.new(2026, 4, 12), report.end_date
    assert_equal "custom", report.preset
    assert_equal 2, report.daily_points.length
  end

  test "invalid reversed range falls back with a message" do
    seed_daily("2026-04-10", pv: 1000, desk: 100, washer: 200)

    report = EnergyReport.new(
      params: { start_date: "2026-04-20", end_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_equal "last_7", report.preset
    assert_equal [ "Der Datumsbereich war ungueltig und wurde auf die letzten 7 Tage zurueckgesetzt." ], report.messages
  end

  test "builds per plug ranking split by role" do
    seed_daily("2026-04-10", pv: 2000, desk: 700, washer: 300)
    seed_daily("2026-04-11", pv: 3000, desk: 500, washer: 1000)

    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert_equal [ "Balkonkraftwerk" ], report.producer_ranking.map { |row| row.fetch(:name) }
    assert_equal [ "Waschmaschine", "Schreibtisch" ], report.consumer_ranking.map { |row| row.fetch(:name) }
    assert_in_delta 5.0, report.producer_ranking.first.fetch(:kwh)
    assert_in_delta 1.2, report.consumer_ranking.second.fetch(:kwh)
  end

  test "builds chart payloads for daily and selected day detail" do
    seed_daily("2026-04-10", pv: 2000, desk: 700, washer: 300)
    start_ts = Time.utc(2026, 4, 10, 0, 0, 0).to_i
    Sample5min.create!(plug_id: "pv", bucket_ts: start_ts, avg_power_w: 120, energy_delta_wh: 10, sample_count: 2)
    Sample5min.create!(plug_id: "desk", bucket_ts: start_ts, avg_power_w: 30, energy_delta_wh: 3, sample_count: 2)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-10", selected_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_equal [ "10.04." ], report.chart_payload.fetch(:daily).fetch(:labels)
    assert_equal [ 2.0 ], report.chart_payload.fetch(:daily).fetch(:produced_kwh)
    assert_equal [ 1.0 ], report.chart_payload.fetch(:daily).fetch(:consumed_kwh)
    assert_equal [ "Schreibtisch", "Waschmaschine" ], report.chart_payload.fetch(:daily).fetch(:consumer_series).map { |row| row.fetch(:name) }
    assert_equal [ 0.7 ], report.chart_payload.fetch(:daily).fetch(:consumer_series).first.fetch(:data)
    assert_equal [ 1.0 ], report.chart_payload.fetch(:daily).fetch(:balance_kwh)
    assert_equal 2, report.chart_payload.fetch(:detail).fetch(:series).length
  end

  test "uses the full detail range for periods up to seven days" do
    seed_daily("2026-04-10", pv: 2000, desk: 700, washer: 300)
    seed_daily("2026-04-11", pv: 3000, desk: 800, washer: 400)
    day_one_ts = Time.utc(2026, 4, 10, 0, 0, 0).to_i
    day_two_ts = Time.utc(2026, 4, 11, 0, 0, 0).to_i
    Sample5min.create!(plug_id: "pv", bucket_ts: day_one_ts, avg_power_w: 120, energy_delta_wh: 10, sample_count: 2)
    Sample5min.create!(plug_id: "pv", bucket_ts: day_two_ts, avg_power_w: 220, energy_delta_wh: 18, sample_count: 2)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-11" },
      plugs: @plugs
    ).build

    detail = report.chart_payload.fetch(:detail)
    assert_equal "line", detail.fetch(:chart_type)
    assert_equal [ "10.04. 00:00", "11.04. 00:00" ], detail.fetch(:labels)
    assert_equal [ 120.0, 220.0 ], detail.fetch(:series).first.fetch(:data)
    assert_equal Date.new(2026, 4, 10), report.detail_start_date
    assert_equal Date.new(2026, 4, 11), report.detail_end_date
  end

  test "uses daily average power detail for periods longer than seven days" do
    8.times do |i|
      seed_daily((Date.new(2026, 4, 10) + i).to_s, pv: 2400 + i * 24, desk: 720, washer: 240)
    end

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-17", selected_date: "2026-04-17" },
      plugs: @plugs
    ).build

    detail = report.chart_payload.fetch(:detail)
    assert_equal "bar", detail.fetch(:chart_type)
    assert_equal [ "10.04.", "11.04.", "12.04.", "13.04.", "14.04.", "15.04.", "16.04.", "17.04." ], detail.fetch(:labels)
    assert_equal [ 100.0, 101.0, 102.0, 103.0, 104.0, 105.0, 106.0, 107.0 ], detail.fetch(:series).first.fetch(:data)
    assert_equal Date.new(2026, 4, 10), report.detail_start_date
    assert_equal Date.new(2026, 4, 17), report.detail_end_date
  end

  test "empty data returns empty state without raising" do
    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert report.empty?
    assert_equal [], report.daily_points
    assert_equal(
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
      },
      report.summary
    )
    assert_equal [], report.chart_payload.fetch(:daily).fetch(:labels)
  end

  test "summary includes self-consumption and ratios from daily_energy_summary" do
    DailyTotal.create!(plug_id: "pv",     date: "2026-04-10", energy_wh: 2000)
    DailyTotal.create!(plug_id: "desk",   date: "2026-04-10", energy_wh: 700)
    DailyTotal.create!(plug_id: "washer", date: "2026-04-10", energy_wh: 300)
    DailyEnergySummary.create!(
      date: "2026-04-10",
      produced_wh: 2000.0,
      consumed_wh: 1000.0,
      self_consumed_wh: 600.0
    )

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_in_delta 2.0, report.summary.fetch(:produced_kwh)
    assert_in_delta 1.0, report.summary.fetch(:consumed_kwh)
    assert_in_delta 0.6, report.summary.fetch(:self_consumed_kwh)
    assert_in_delta 0.6, report.summary.fetch(:autarky_ratio),           0.001
    assert_in_delta 0.3, report.summary.fetch(:self_consumption_ratio), 0.001
  end

  test "ratios are zero when denominators are zero" do
    DailyEnergySummary.create!(
      date: "2026-04-10",
      produced_wh: 0.0,
      consumed_wh: 0.0,
      self_consumed_wh: 0.0
    )
    DailyTotal.create!(plug_id: "pv", date: "2026-04-10", energy_wh: 0)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-10" },
      plugs: @plugs
    ).build

    assert_equal 0.0, report.summary.fetch(:autarky_ratio)
    assert_equal 0.0, report.summary.fetch(:self_consumption_ratio)
  end

  test "chart payload includes per-day ratios with nulls for gaps" do
    DailyTotal.create!(plug_id: "pv", date: "2026-04-10", energy_wh: 2000)
    DailyTotal.create!(plug_id: "pv", date: "2026-04-11", energy_wh: 2000)
    DailyEnergySummary.create!(date: "2026-04-10", produced_wh: 2000.0, consumed_wh: 1000.0, self_consumed_wh: 500.0)
    # 2026-04-11 has no daily_energy_summary row -> gap

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-11" },
      plugs: @plugs
    ).build

    ratios = report.chart_payload.fetch(:daily).fetch(:ratios)
    assert_equal 2, ratios.length
    assert_equal "2026-04-10", ratios.first.fetch(:date)
    assert_in_delta 50.0, ratios.first.fetch(:autarky_pct),           0.001
    assert_in_delta 25.0, ratios.first.fetch(:self_consumption_pct), 0.001
    assert_nil ratios.last.fetch(:autarky_pct)
    assert_nil ratios.last.fetch(:self_consumption_pct)
  end

  test "summary excludes days without daily_energy_summary from totals" do
    DailyTotal.create!(plug_id: "pv", date: "2026-04-10", energy_wh: 2000)
    DailyTotal.create!(plug_id: "pv", date: "2026-04-11", energy_wh: 2000)
    DailyEnergySummary.create!(date: "2026-04-10", produced_wh: 2000.0, consumed_wh: 1000.0, self_consumed_wh: 500.0)

    report = EnergyReport.new(
      params: { start_date: "2026-04-10", end_date: "2026-04-11" },
      plugs: @plugs
    ).build

    assert_in_delta 2.0, report.summary.fetch(:produced_kwh)
    assert_in_delta 1.0, report.summary.fetch(:consumed_kwh)
    assert_in_delta 0.5, report.summary.fetch(:self_consumed_kwh)
  end

  private

  def seed_daily(date, pv:, desk:, washer:)
    DailyTotal.create!(plug_id: "pv",     date: date, energy_wh: pv)
    DailyTotal.create!(plug_id: "desk",   date: date, energy_wh: desk)
    DailyTotal.create!(plug_id: "washer", date: date, energy_wh: washer)
    DailyEnergySummary.create!(
      date:             date,
      produced_wh:      pv,
      consumed_wh:      desk + washer,
      self_consumed_wh: 0.0
    )
  end
end
