require "test_helper"
require "weather_broadcaster"

class WeatherBroadcasterTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup { WeatherRecord.delete_all }

  test "broadcast_current sends a turbo stream replace for the current frame" do
    payload = capture_one { WeatherBroadcaster.broadcast_current }

    assert_match %r{<turbo-stream action="replace" target="weather_current">}, payload
    assert_match %r{<turbo-frame id="weather_current">}, payload
  end

  test "broadcast_today sends a turbo stream replace for the today frame" do
    payload = capture_one { WeatherBroadcaster.broadcast_today }

    assert_match %r{<turbo-stream action="replace" target="weather_today">}, payload
    assert_match %r{<turbo-frame id="weather_today">}, payload
  end

  test "broadcast_forecast sends a turbo stream replace for the forecast frame" do
    payload = capture_one { WeatherBroadcaster.broadcast_forecast }

    assert_match %r{<turbo-stream action="replace" target="weather_forecast">}, payload
    assert_match %r{<turbo-frame id="weather_forecast">}, payload
  end

  private

  def capture_one(&block)
    block.call
    messages = broadcasts(WeatherBroadcaster::STREAM)
    assert_equal 1, messages.size, "expected exactly one broadcast"
    JSON.parse(messages.first)
  end
end
