require "test_helper"
require "daily_energy_summary_builder"

class DailyEnergySummaryBuilderTest < ActiveSupport::TestCase
  setup do
    Sample5min.delete_all
    @plugs = [
      ConfigLoader::PlugCfg.new(id: "pv",     name: "PV",      role: :producer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "desk",   name: "Desk",    role: :consumer, driver: :shelly, ain: nil),
      ConfigLoader::PlugCfg.new(id: "washer", name: "Washer",  role: :consumer, driver: :shelly, ain: nil)
    ]
    @tz = TZInfo::Timezone.get("Europe/Berlin")
    @date = "2026-04-10"
    @midnight = @tz.local_to_utc(Time.parse("#{@date} 00:00:00")).to_i
  end

  def write_5min(plug_id:, offset_min:, avg_w:)
    Sample5min.create!(
      plug_id: plug_id,
      bucket_ts: @midnight + offset_min * 60,
      avg_power_w: avg_w,
      energy_delta_wh: avg_w * 300.0 / 3600.0,
      sample_count: 1
    )
  end

  test "returns zero for a day with no buckets" do
    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)
    assert_in_delta 0.0, result.fetch(:produced_wh)
    assert_in_delta 0.0, result.fetch(:consumed_wh)
    assert_in_delta 0.0, result.fetch(:self_consumed_wh)
  end

  test "consumer-only day yields zero self-consumption" do
    write_5min(plug_id: "desk", offset_min: 0, avg_w: 100)
    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)
    assert_in_delta 0.0,           result.fetch(:produced_wh)
    assert_in_delta 100.0 * 5/60.0, result.fetch(:consumed_wh)
    assert_in_delta 0.0,           result.fetch(:self_consumed_wh)
  end

  test "producer-only day yields zero self-consumption" do
    write_5min(plug_id: "pv", offset_min: 0, avg_w: 200)
    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)
    assert_in_delta 200.0 * 5/60.0, result.fetch(:produced_wh)
    assert_in_delta 0.0,           result.fetch(:consumed_wh)
    assert_in_delta 0.0,           result.fetch(:self_consumed_wh)
  end

  test "self-consumption is min of producer and consumer per bucket" do
    write_5min(plug_id: "pv",   offset_min: 0,  avg_w: 200)
    write_5min(plug_id: "desk", offset_min: 0,  avg_w: 100)
    write_5min(plug_id: "pv",   offset_min: 5,  avg_w:  50)
    write_5min(plug_id: "desk", offset_min: 5,  avg_w: 300)

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    bucket_h = 5.0 / 60.0
    assert_in_delta (200 + 50) * bucket_h, result.fetch(:produced_wh)
    assert_in_delta (100 + 300) * bucket_h, result.fetch(:consumed_wh)
    assert_in_delta (100 +  50) * bucket_h, result.fetch(:self_consumed_wh)
  end

  test "sums multiple consumers per bucket before taking the min" do
    write_5min(plug_id: "pv",     offset_min: 0, avg_w: 250)
    write_5min(plug_id: "desk",   offset_min: 0, avg_w: 100)
    write_5min(plug_id: "washer", offset_min: 0, avg_w: 200)

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    bucket_h = 5.0 / 60.0
    assert_in_delta 250 * bucket_h, result.fetch(:produced_wh)
    assert_in_delta 300 * bucket_h, result.fetch(:consumed_wh)
    assert_in_delta 250 * bucket_h, result.fetch(:self_consumed_wh)
  end

  test "ignores buckets outside the requested local day" do
    write_5min(plug_id: "pv",   offset_min: 0,         avg_w: 200)
    write_5min(plug_id: "desk", offset_min: 0,         avg_w: 100)
    write_5min(plug_id: "pv",   offset_min: 24 * 60,   avg_w: 999)

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    bucket_h = 5.0 / 60.0
    assert_in_delta 200 * bucket_h, result.fetch(:produced_wh)
    assert_in_delta 100 * bucket_h, result.fetch(:consumed_wh)
    assert_in_delta 100 * bucket_h, result.fetch(:self_consumed_wh)
  end

  test "self-consumption uses avg_power_w even when energy_delta_wh is clipped" do
    bucket_h = 5.0 / 60.0

    # Producer counter glitched: avg_power_w is real, but the per-sample
    # plausibility cap zeroed every delta -> energy_delta_wh = 0 for the bucket.
    Sample5min.create!(
      plug_id: "pv", bucket_ts: @midnight, avg_power_w: 200.0,
      energy_delta_wh: 0.0, sample_count: 60
    )
    # Consumer is healthy.
    Sample5min.create!(
      plug_id: "desk", bucket_ts: @midnight, avg_power_w: 150.0,
      energy_delta_wh: 150.0 * bucket_h, sample_count: 60
    )

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    # produced_wh stays at the metered (clipped) value — that's what the
    # counter said. But self-consumption reflects the real overlap power.
    # Clamp ensures self_consumed_wh ≤ produced_wh = 0 in this degenerate case.
    assert_in_delta 0.0,           result.fetch(:produced_wh)
    assert_in_delta 150 * bucket_h, result.fetch(:consumed_wh)
    assert_in_delta 0.0,           result.fetch(:self_consumed_wh)
  end

  test "self-consumption clamps to consumed when overlap power exceeds metered consumption" do
    bucket_h = 5.0 / 60.0

    Sample5min.create!(
      plug_id: "pv", bucket_ts: @midnight, avg_power_w: 200.0,
      energy_delta_wh: 200.0 * bucket_h, sample_count: 60
    )
    # Consumer counter glitched: avg_power_w real, energy_delta_wh = 0.
    Sample5min.create!(
      plug_id: "desk", bucket_ts: @midnight, avg_power_w: 100.0,
      energy_delta_wh: 0.0, sample_count: 60
    )

    result = DailyEnergySummaryBuilder.new(plugs: @plugs, timezone: @tz).build(@date)

    assert_in_delta 200 * bucket_h, result.fetch(:produced_wh)
    assert_in_delta 0.0,           result.fetch(:consumed_wh)
    assert_in_delta 0.0,           result.fetch(:self_consumed_wh)
  end
end
