require "test_helper"

class WeatherForecastJobTest < ActiveJob::TestCase
  test "runs forecast sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_forecast, nil, today: Date.new(2026, 5, 4))
    WeatherSync.stub(:from_app_config, sync) { WeatherForecastJob.perform_now(today: Date.new(2026, 5, 4)) }
    assert sync.verify
  end
end
