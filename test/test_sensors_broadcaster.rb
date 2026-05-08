require "test_helper"
require "sensors_broadcaster"

class SensorsBroadcasterTest < ActiveSupport::TestCase
  test "broadcasts replace to sensors stream targeting the dashboard" do
    calls = []
    Turbo::StreamsChannel.stub(:broadcast_replace_to,
                               ->(stream, **opts) { calls << [ stream, opts[:target] ] }) do
      SensorsBroadcaster.refresh
    end
    assert_includes calls, [ "sensors", "sensors_dashboard" ]
  end

  test "refresh re-broadcasts the weather current frame" do
    called = false
    WeatherBroadcaster.stub(:broadcast_current, -> { called = true }) do
      Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kw) {}) do
        SensorsBroadcaster.refresh
      end
    end
    assert called, "expected WeatherBroadcaster.broadcast_current to be invoked"
  end

  test "refresh is a no-op when no sensors are configured" do
    fake_config = Struct.new(:switchbot, :sensors).new(nil, [])
    sensor_calls  = 0
    weather_calls = 0
    SensorsBroadcaster.stub(:load_config, fake_config) do
      Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kw) { sensor_calls += 1 }) do
        WeatherBroadcaster.stub(:broadcast_current, -> { weather_calls += 1 }) do
          SensorsBroadcaster.refresh
        end
      end
    end
    assert_equal 0, sensor_calls
    assert_equal 0, weather_calls
  end
end
