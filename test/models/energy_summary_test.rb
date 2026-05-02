require "test_helper"

class EnergySummaryTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    DailyTotal.delete_all

    plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, host: "h1", ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, host: "h2", ain: nil)
    poll = ConfigLoader::PollCfg.new(interval_seconds: 5, timeout_seconds: 2,
                                     circuit_breaker_threshold: 3, circuit_breaker_probe_seconds: 30)
    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      poll: poll,
      aggregator: nil,
      plugs: [plug_bkw, plug_fridge],
      fritz_box: nil
    )
  end

  test "compute_today returns produced, consumed, savings and date" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    Sample.create!(plug_id: "bkw",    ts: midnight + 60,   apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "bkw",    ts: midnight + 3600, apower_w: 0, aenergy_wh: 1000.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 60,   apower_w: 0, aenergy_wh: 500.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 3600, apower_w: 0, aenergy_wh: 600.0)

    summary = EnergySummary.new(config: @config).compute_today

    assert_in_delta 1000.0, summary.produced_wh
    assert_in_delta 100.0,  summary.consumed_wh
    assert_in_delta 0.32,   summary.savings_eur
    assert_equal Date.today.to_s, summary.date
  end

  test "compute_today returns zero when no samples" do
    summary = EnergySummary.new(config: @config).compute_today
    assert_in_delta 0.0, summary.produced_wh
    assert_in_delta 0.0, summary.consumed_wh
    assert_in_delta 0.0, summary.savings_eur
    assert_equal Date.today.to_s, summary.date
  end

  test "compute_today handles meter reset" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    Sample.create!(plug_id: "fridge", ts: midnight + 60,  apower_w: 0, aenergy_wh: 424_440.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 120, apower_w: 0, aenergy_wh: 0.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 180, apower_w: 0, aenergy_wh: 50.0)

    summary = EnergySummary.new(config: @config).compute_today

    assert_in_delta 50.0, summary.consumed_wh
  end

  test "compute_today ignores glitch zero then jump back" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    Sample.create!(plug_id: "fridge", ts: midnight + 60, apower_w: 145, aenergy_wh: 425_000.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 65, apower_w: 145, aenergy_wh: 0.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 70, apower_w: 145, aenergy_wh: 425_005.0)
    Sample.create!(plug_id: "fridge", ts: midnight + 75, apower_w: 145, aenergy_wh: 425_010.0)

    summary = EnergySummary.new(config: @config).compute_today

    assert_in_delta 5.0, summary.consumed_wh
  end
end
