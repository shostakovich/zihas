require "test_helper"

class WeatherTodayJobTest < ActiveJob::TestCase
  test "runs today sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_today, nil, today: Date.new(2026, 5, 4))
    WeatherBroadcaster.stub(:broadcast_today, nil) do
      WeatherSync.stub(:from_app_config, sync) { WeatherTodayJob.perform_now(today: Date.new(2026, 5, 4)) }
    end
    assert sync.verify
  end

  test "broadcasts today frame after sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_today, nil, today: Date.new(2026, 5, 4))
    calls = []
    WeatherBroadcaster.stub(:broadcast_today, -> { calls << :today }) do
      WeatherSync.stub(:from_app_config, sync) { WeatherTodayJob.perform_now(today: Date.new(2026, 5, 4)) }
    end
    assert_equal [ :today ], calls
  end
end
