require "test_helper"

class EnergyReportTest < ActiveSupport::TestCase
  setup do
    DailyTotal.delete_all
    Sample5min.delete_all

    @plugs = [
      ConfigLoader::PlugCfg.new(id: "pv", name: "Balkonkraftwerk", role: :producer, driver: :shelly, host: "pv.local", ain: nil),
      ConfigLoader::PlugCfg.new(id: "desk", name: "Schreibtisch", role: :consumer, driver: :shelly, host: "desk.local", ain: nil),
      ConfigLoader::PlugCfg.new(id: "washer", name: "Waschmaschine", role: :consumer, driver: :shelly, host: "washer.local", ain: nil),
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
    assert_in_delta 6.58, report.summary.fetch(:balance_kwh)
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

    assert_equal [ "2026-04-10" ], report.chart_payload.fetch(:daily).fetch(:labels)
    assert_equal [ 2.0 ], report.chart_payload.fetch(:daily).fetch(:produced_kwh)
    assert_equal [ 1.0 ], report.chart_payload.fetch(:daily).fetch(:consumed_kwh)
    assert_equal 2, report.chart_payload.fetch(:detail).fetch(:series).length
  end

  test "empty data returns empty state without raising" do
    report = EnergyReport.new(params: {}, plugs: @plugs).build

    assert report.empty?
    assert_equal [], report.daily_points
    assert_equal({ produced_kwh: 0.0, consumed_kwh: 0.0, balance_kwh: 0.0 }, report.summary)
    assert_equal [], report.chart_payload.fetch(:daily).fetch(:labels)
  end

  private

  def seed_daily(date, pv:, desk:, washer:)
    DailyTotal.create!(plug_id: "pv", date: date, energy_wh: pv)
    DailyTotal.create!(plug_id: "desk", date: date, energy_wh: desk)
    DailyTotal.create!(plug_id: "washer", date: date, energy_wh: washer)
  end
end
