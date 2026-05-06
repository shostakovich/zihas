require "test_helper"

class WeatherSegmentTest < ActiveSupport::TestCase
  def make_record(hour:, icon: "clear-day", daytime: "day", temperature: 15, precipitation: nil, solar: nil)
    WeatherRecord.new(
      kind: "forecast",
      lat: 52.52, lon: 13.405,
      timestamp: Time.zone.local(2026, 5, 6, hour),
      icon: icon, daytime: daytime,
      temperature: temperature, precipitation: precipitation, solar: solar
    )
  end

  def segment(records, label: "Nachmittag", hour_range: 12...18)
    WeatherSegment.new(label: label, hour_range: hour_range, records: records)
  end

  test "dominant_icon returns most severe icon across the window" do
    records = [
      make_record(hour: 12, icon: "clear-day"),
      make_record(hour: 13, icon: "partly-cloudy-day"),
      make_record(hour: 14, icon: "thunderstorm"),
      make_record(hour: 15, icon: "clear-day"),
      make_record(hour: 16, icon: "rain"),
      make_record(hour: 17, icon: "clear-day")
    ]
    assert_equal "thunderstorm", segment(records).dominant_icon
  end

  test "dominant_icon falls back to unknown for empty segment" do
    assert_equal "unknown", segment([]).dominant_icon
  end

  test "dominant_icon returns earliest record on severity tie" do
    records = [
      make_record(hour: 12, icon: "rain"),
      make_record(hour: 13, icon: "clear-day"),
      make_record(hour: 14, icon: "rain")
    ]
    assert_equal "rain", segment(records).dominant_icon
  end

  test "temp_min and temp_max ignore nil temperatures" do
    records = [
      make_record(hour: 12, temperature: 11),
      make_record(hour: 13, temperature: nil),
      make_record(hour: 14, temperature: 17)
    ]
    seg = segment(records)
    assert_equal 11, seg.temp_min
    assert_equal 17, seg.temp_max
  end

  test "precip_sum treats nil as zero" do
    records = [
      make_record(hour: 12, precipitation: 0.4),
      make_record(hour: 13, precipitation: nil),
      make_record(hour: 14, precipitation: 1.4)
    ]
    assert_in_delta 1.8, segment(records).precip_sum, 0.001
  end

  test "avg_solar_w_per_m2 averages over records with solar, ignoring nils" do
    records = [
      make_record(hour: 12, solar: 0.30),
      make_record(hour: 13, solar: nil),
      make_record(hour: 14, solar: 0.50)
    ]
    assert_in_delta 400.0, segment(records).avg_solar_w_per_m2, 0.001
  end

  test "avg_solar_w_per_m2 returns nil when no records have solar" do
    records = [ make_record(hour: 12, solar: nil), make_record(hour: 13, solar: nil) ]
    assert_nil segment(records).avg_solar_w_per_m2
  end

  test "all_night? is true only when at least one record exists and all are night" do
    night = [
      make_record(hour: 0, daytime: "night"),
      make_record(hour: 1, daytime: "night")
    ]
    mixed = [
      make_record(hour: 18, daytime: "day"),
      make_record(hour: 19, daytime: "night")
    ]
    assert segment(night, label: "Nacht", hour_range: 0...6).all_night?
    refute segment(mixed, label: "Abend", hour_range: 18...24).all_night?
    refute segment([], label: "Nacht", hour_range: 0...6).all_night?
  end

  test "dominant_daytime picks the daytime of the most-severe-icon record" do
    records = [
      make_record(hour: 18, icon: "clear-day", daytime: "day"),
      make_record(hour: 19, icon: "thunderstorm", daytime: "night"),
      make_record(hour: 20, icon: "clear-night", daytime: "night")
    ]
    seg = segment(records, label: "Abend", hour_range: 18...24)
    assert_equal "night", seg.dominant_daytime
  end

  test "expected_hours, available_hours, complete?/partial?/empty? reflect record count" do
    six = (12...18).map { |h| make_record(hour: h) }
    seg = segment(six)
    assert_equal 6, seg.expected_hours
    assert_equal 6, seg.available_hours
    assert seg.complete?
    refute seg.partial?
    refute seg.empty?

    partial = segment(six.first(3))
    assert_equal 6, partial.expected_hours
    assert_equal 3, partial.available_hours
    refute partial.complete?
    assert partial.partial?
    refute partial.empty?

    empty = segment([])
    assert_equal 6, empty.expected_hours
    assert_equal 0, empty.available_hours
    refute empty.complete?
    refute empty.partial?
    assert empty.empty?
  end

  test "asset_name combines dominant icon and dominant daytime" do
    records = [
      make_record(hour: 12, icon: "clear-day", daytime: "day"),
      make_record(hour: 14, icon: "thunderstorm", daytime: "day")
    ]
    assert_equal "weather_thunderstorm_day.webp", segment(records).asset_name
  end
end
