require_relative "application_system_test_case"

class WeatherSegmentsTest < ApplicationSystemTestCase
  setup do
    WeatherRecord.delete_all
    travel_to Time.zone.local(2026, 5, 4, 12, 0)

    {
      "02:00" => "night",
      "08:00" => "day",
      "14:00" => "day",
      "20:00" => "day"
    }.each do |hhmm, daytime|
      WeatherRecord.create!(
        kind: "forecast", lat: 52.52, lon: 13.405,
        timestamp: Time.zone.parse("2026-05-05 #{hhmm}"),
        daytime: daytime,
        icon: daytime == "night" ? "clear-night" : "clear-day",
        temperature: 15
      )
    end
  end

  teardown { travel_back }

  test "clicking a segment expands its hour row, clicking again collapses, switching swaps" do
    visit "/weather"

    assert_selector ".weather-day-hours .weather-day-hour-row", count: 4, visible: :hidden

    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="2"]').click
    end

    within first(".weather-day-hours") do
      assert_selector '.weather-day-hour-row[data-segment-index="2"]', visible: :visible
      assert_selector '.weather-day-hour-row[data-segment-index="0"]', visible: :hidden
      assert_selector '.weather-day-hour-row[data-segment-index="1"]', visible: :hidden
      assert_selector '.weather-day-hour-row[data-segment-index="3"]', visible: :hidden
    end

    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="2"]').click
    end
    assert_selector ".weather-day-hours .weather-day-hour-row", count: 4, visible: :hidden

    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="1"]').click
    end
    within first(".weather-day-hours") do
      assert_selector '.weather-day-hour-row[data-segment-index="1"]', visible: :visible
    end
    within first(".weather-day-segments") do
      find('button.weather-segment[data-segment-index="2"]').click
    end
    within first(".weather-day-hours") do
      assert_selector '.weather-day-hour-row[data-segment-index="2"]', visible: :visible
      assert_selector '.weather-day-hour-row[data-segment-index="1"]', visible: :hidden
    end
  end
end
