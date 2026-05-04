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
    records = [make_record(timestamp: date.to_time + 12.hours, temperature: 17, solar: 0.48)]

    day = WeatherDay.from_records(date, records)

    assert_in_delta 480.0, day.solar_peak_w_per_m2
  end

  test "solar_peak_w_per_m2 is nil when no record has a solar value" do
    date = Date.new(2026, 5, 6)
    records = [make_record(timestamp: date.to_time + 12.hours, temperature: 17)]

    day = WeatherDay.from_records(date, records)

    assert_nil day.solar_peak_w_per_m2
  end

  test "from_records exposes the date and the records list" do
    date = Date.new(2026, 5, 6)
    records = [make_record(timestamp: date.to_time + 12.hours, temperature: 15)]

    day = WeatherDay.from_records(date, records)

    assert_equal date, day.date
    assert_equal records, day.records
  end
end
