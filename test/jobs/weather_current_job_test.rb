require "test_helper"

class WeatherCurrentJobTest < ActiveJob::TestCase
  test "runs sync when weather is configured" do
    sync = Minitest::Mock.new
    sync.expect(:sync_current, nil)
    WeatherSync.stub(:from_app_config, sync) { WeatherCurrentJob.perform_now }
    assert sync.verify
  end

  test "does nothing when weather is not configured" do
    WeatherSync.stub(:from_app_config, nil) { WeatherCurrentJob.perform_now }
  end
end
