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
      Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(*args, **kw) { }) do
        SensorsBroadcaster.refresh
      end
    end
    assert called, "expected WeatherBroadcaster.broadcast_current to be invoked"
  end

  test "dashboard partial renders with only sensors and latest locals" do
    sensor = Struct.new(:id, :name, :type, :room).new("A", "Probe", :meter_pro_co2, nil)
    SensorReading.create!(device_id: "A", taken_at: Time.current,
                          temperature: 22.0, humidity: 40, co2: 600, battery_pct: 80)
    fake_config = Struct.new(:switchbot, :sensors).new(nil, [ sensor ])
    SensorsBroadcaster.stub(:load_config, fake_config) do
      WeatherBroadcaster.stub(:broadcast_current, -> { }) do
        captured = nil
        stub = ->(_stream, **opts) { captured = opts }
        Turbo::StreamsChannel.stub(:broadcast_replace_to, stub) do
          SensorsBroadcaster.refresh
        end
        refute_nil captured, "expected a broadcast carrying the partial and locals"
        rendered = SensorsController.render(partial: captured[:partial], locals: captured[:locals])
        assert_includes rendered, "Probe", "expected the sensor to appear in the rendered partial"
      end
    end
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

  test "dashboard partial renders cleanly without a controller context" do
    sensor = Struct.new(:id, :name, :type, :room).new("A", "Probe", :meter_pro_co2, nil)
    SensorReading.create!(device_id: "A", taken_at: Time.current,
                          temperature: 22.0, humidity: 40, co2: 600, battery_pct: 80)
    fake_config = Struct.new(:switchbot, :sensors).new(nil, [ sensor ])

    rendered = nil
    SensorsBroadcaster.stub(:load_config, fake_config) do
      WeatherBroadcaster.stub(:broadcast_current, -> { }) do
        Turbo::StreamsChannel.stub(:broadcast_replace_to, ->(_stream, **opts) {
          rendered = ApplicationController.render(partial: opts[:partial], locals: opts[:locals])
        }) do
          SensorsBroadcaster.refresh
        end
      end
    end

    refute_nil rendered, "expected the partial to render"
    assert_includes rendered, "Probe", "expected the sensor card to render its name"
  end
end
