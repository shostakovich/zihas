require "test_helper"

class WeatherForecastJobTest < ActiveJob::TestCase
  test "runs forecast sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_forecast, nil, today: Date.new(2026, 5, 4))
    WeatherBroadcaster.stub(:broadcast_today, nil) do
      WeatherBroadcaster.stub(:broadcast_forecast, nil) do
        WeatherSync.stub(:from_app_config, sync) { WeatherForecastJob.perform_now(today: Date.new(2026, 5, 4)) }
      end
    end
    assert sync.verify
  end

  test "broadcasts today and forecast frames after sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_forecast, nil, today: Date.new(2026, 5, 4))
    calls = []
    WeatherBroadcaster.stub(:broadcast_today, -> { calls << :today }) do
      WeatherBroadcaster.stub(:broadcast_forecast, -> { calls << :forecast }) do
        WeatherSync.stub(:from_app_config, sync) { WeatherForecastJob.perform_now(today: Date.new(2026, 5, 4)) }
      end
    end
    assert_equal [ :today, :forecast ], calls
  end
end
