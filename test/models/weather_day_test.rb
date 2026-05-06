require "test_helper"

class WeatherDayTest < ActiveSupport::TestCase
  def make_record(timestamp:, temperature:, precipitation: nil, solar: nil, daytime: "day")
    WeatherRecord.new(
      kind: "forecast",
      lat: 52.52, lon: 13.405,
      timestamp: timestamp, daytime: daytime, icon: "clear-day",
      temperature: temperature, precipitation: precipitation, solar: solar
    )
  end

  test "from_records computes min/max temperature" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 6.hours, temperature: 11),
      make_record(timestamp: date.to_time + 12.hours, temperature: 17),
      make_record(timestamp: date.to_time + 18.hours, temperature: 14)
    ]

    day = WeatherDay.from_records(date, records)

    assert_equal 11, day.temp_min
    assert_equal 17, day.temp_max
  end

  test "from_records sums precipitation treating nil as zero" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 6.hours, temperature: 12, precipitation: 0.4),
      make_record(timestamp: date.to_time + 9.hours, temperature: 13, precipitation: nil),
      make_record(timestamp: date.to_time + 12.hours, temperature: 15, precipitation: 1.4)
    ]

    day = WeatherDay.from_records(date, records)

    assert_in_delta 1.8, day.precip_sum, 0.001
  end

  test "from_records picks max solar value" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 9.hours, temperature: 13, solar: 220),
      make_record(timestamp: date.to_time + 12.hours, temperature: 17, solar: 480),
      make_record(timestamp: date.to_time + 15.hours, temperature: 17, solar: 380)
    ]

    day = WeatherDay.from_records(date, records)

    assert_equal 480, day.solar_peak
  end

  test "from_records returns nil solar_peak when every record has nil solar" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 9.hours, temperature: 13),
      make_record(timestamp: date.to_time + 12.hours, temperature: 17)
    ]

    day = WeatherDay.from_records(date, records)

    assert_nil day.solar_peak
  end

  test "solar_peak_w_per_m2 converts the peak from kWh/m² to W/m²" do
    date = Date.new(2026, 5, 6)
    records = [ make_record(timestamp: date.to_time + 12.hours, temperature: 17, solar: 0.48) ]

    day = WeatherDay.from_records(date, records)

    assert_in_delta 480.0, day.solar_peak_w_per_m2
  end

  test "solar_peak_w_per_m2 is nil when no record has a solar value" do
    date = Date.new(2026, 5, 6)
    records = [ make_record(timestamp: date.to_time + 12.hours, temperature: 17) ]

    day = WeatherDay.from_records(date, records)

    assert_nil day.solar_peak_w_per_m2
  end

  test "weekday_label returns the full German weekday name" do
    assert_equal "Montag", WeatherDay.from_records(Date.new(2026, 5, 4), []).weekday_label
    assert_equal "Sonntag", WeatherDay.from_records(Date.new(2026, 5, 3), []).weekday_label
  end

  test "date_label formats as DD.MM." do
    assert_equal "04.05.", WeatherDay.from_records(Date.new(2026, 5, 4), []).date_label
    assert_equal "31.03.", WeatherDay.from_records(Date.new(2026, 3, 31), []).date_label
  end

  test "from_records exposes the date and the records list" do
    date = Date.new(2026, 5, 6)
    records = [ make_record(timestamp: date.to_time + 12.hours, temperature: 15) ]

    day = WeatherDay.from_records(date, records)

    assert_equal date, day.date
    assert_equal records, day.records
  end

  test "segments returns four segments in display order with correct labels and hour ranges" do
    date = Date.new(2026, 5, 6)
    records = (0..23).map do |h|
      make_record(timestamp: date.to_time + h.hours, temperature: 10 + h, daytime: h < 6 ? "night" : "day")
    end

    day = WeatherDay.from_records(date, records)
    segs = day.segments

    assert_equal 4, segs.size
    assert_equal %w[Nacht Vormittag Nachmittag Abend], segs.map(&:label)
    assert_equal [ 0...6, 6...12, 12...18, 18...24 ], segs.map(&:hour_range)
    assert_equal 6, segs[0].records.size
    assert_equal 6, segs[1].records.size
    assert_equal 6, segs[2].records.size
    assert_equal 6, segs[3].records.size
  end

  test "segments place a 06:00 record into Vormittag, not Nacht" do
    date = Date.new(2026, 5, 6)
    records = [
      make_record(timestamp: date.to_time + 5.hours, temperature: 8, daytime: "night"),
      make_record(timestamp: date.to_time + 6.hours, temperature: 9, daytime: "day")
    ]
    segs = WeatherDay.from_records(date, records).segments

    assert_equal 1, segs[0].records.size
    assert_equal 1, segs[1].records.size
    assert_equal 0, segs[2].records.size
    assert_equal 0, segs[3].records.size
  end

  test "segments are present even when day has no records" do
    segs = WeatherDay.from_records(Date.new(2026, 5, 6), []).segments
    assert_equal 4, segs.size
    assert(segs.all? { |s| s.records.empty? })
  end
end
