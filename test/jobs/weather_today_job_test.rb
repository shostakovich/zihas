require "test_helper"

class WeatherTodayJobTest < ActiveJob::TestCase
  test "runs today sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_today, nil, today: Date.new(2026, 5, 4))
    WeatherSync.stub(:from_app_config, sync) { WeatherTodayJob.perform_now(today: Date.new(2026, 5, 4)) }
    assert sync.verify
  end
end
