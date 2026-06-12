require "test_helper"
require "weather_broadcaster"

class WeatherBroadcasterTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup { WeatherRecord.delete_all }

  test "broadcast_current sends replaces for the current frame and empty state" do
    payloads = capture_payloads { WeatherBroadcaster.broadcast_current }

    assert_replace_for "weather_current", payloads
    assert_replace_for "weather_empty", payloads
  end

  test "broadcast_today sends replaces for the today frame and empty state" do
    payloads = capture_payloads { WeatherBroadcaster.broadcast_today }

    assert_replace_for "weather_today", payloads
    assert_replace_for "weather_empty", payloads
  end

  test "broadcast_forecast sends replaces for the forecast frame and empty state" do
    payloads = capture_payloads { WeatherBroadcaster.broadcast_forecast }

    assert_replace_for "weather_forecast", payloads
    assert_replace_for "weather_empty", payloads
  end

  test "empty state renders the placeholder when no weather data exists" do
    payload = capture_payloads { WeatherBroadcaster.broadcast_empty_state }
      .find { |p| p.include?(%(target="weather_empty")) }

    assert_match %r{Noch keine Wetterdaten}, payload
  end

  test "empty state hides the placeholder once weather data exists" do
    WeatherRecord.create!(kind: "current", lat: 52.52, lon: 13.405,
      timestamp: Time.zone.now, daytime: "day", icon: "clear-day", temperature: 18)

    payload = capture_payloads { WeatherBroadcaster.broadcast_empty_state }
      .find { |p| p.include?(%(target="weather_empty")) }

    assert_match %r{<turbo-frame id="weather_empty">\s*</turbo-frame>}, payload
    refute_match %r{Noch keine Wetterdaten}, payload
  end

  private

  def capture_payloads(&block)
    block.call
    broadcasts(WeatherBroadcaster::STREAM).map { |raw| JSON.parse(raw) }
  end

  def assert_replace_for(target, payloads)
    matched = payloads.any? { |p| p.include?(%(target="#{target}")) && p.include?(%(<turbo-frame id="#{target}">)) }
    assert matched, "expected a turbo-stream replace for #{target} in #{payloads.inspect}"
  end
end
