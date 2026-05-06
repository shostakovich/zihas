require "test_helper"

class EnergySummaryTest < ActiveSupport::TestCase
  setup do
    Sample.delete_all
    DailyTotal.delete_all

    plug_bkw    = ConfigLoader::PlugCfg.new(id: "bkw",    name: "BKW",   role: :producer, driver: :shelly, ain: nil)
    plug_fridge = ConfigLoader::PlugCfg.new(id: "fridge", name: "Fridge", role: :consumer, driver: :shelly, ain: nil)
    mqtt = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
    @config = ConfigLoader::Config.new(
      electricity_price_eur_per_kwh: 0.32,
      timezone: "Europe/Berlin",
      mqtt: mqtt,
      fritz_poll: nil,
      plugs: [ plug_bkw, plug_fridge ],
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

  test "compute_today returns self_consumed_wh from simultaneous overlap" do
    tz       = TZInfo::Timezone.get("Europe/Berlin")
    midnight = tz.local_to_utc(Time.parse("#{Date.today} 00:00:00")).to_i

    # 1h of producer 200W and consumer 100W simultaneously
    (0..3600).step(60) do |dt|
      Sample.create!(plug_id: "bkw",    ts: midnight + dt, apower_w: 200.0, aenergy_wh: 200.0 * dt / 3600.0)
      Sample.create!(plug_id: "fridge", ts: midnight + dt, apower_w: 100.0, aenergy_wh: 100.0 * dt / 3600.0)
    end

    summary = EnergySummary.new(config: @config).compute_today

    assert_in_delta 200.0, summary.produced_wh,      2.0
    assert_in_delta 100.0, summary.consumed_wh,      2.0
    assert_in_delta 100.0, summary.self_consumed_wh, 2.0
    assert_in_delta 1.0,   summary.autarky_ratio,           0.05
    assert_in_delta 0.5,   summary.self_consumption_ratio,  0.05
  end

  test "compute_today ratios are zero when denominator is zero" do
    summary = EnergySummary.new(config: @config).compute_today
    assert_equal 0.0, summary.autarky_ratio
    assert_equal 0.0, summary.self_consumption_ratio
  end
end
