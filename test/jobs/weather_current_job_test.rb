require "test_helper"

class WeatherCurrentJobTest < ActiveJob::TestCase
  test "runs sync when weather is configured" do
    sync = Minitest::Mock.new
    sync.expect(:sync_current, nil)
    WeatherBroadcaster.stub(:broadcast_current, nil) do
      WeatherSync.stub(:from_app_config, sync) { WeatherCurrentJob.perform_now }
    end
    assert sync.verify
  end

  test "does nothing when weather is not configured" do
    assert_nothing_raised do
      WeatherSync.stub(:from_app_config, nil) { WeatherCurrentJob.perform_now }
    end
  end

  test "broadcasts current frame after sync" do
    sync = Minitest::Mock.new
    sync.expect(:sync_current, nil)
    calls = []
    WeatherBroadcaster.stub(:broadcast_current, -> { calls << :current }) do
      WeatherSync.stub(:from_app_config, sync) { WeatherCurrentJob.perform_now }
    end
    assert_equal [ :current ], calls
  end

  test "does not broadcast when weather is not configured" do
    calls = []
    WeatherBroadcaster.stub(:broadcast_current, -> { calls << :current }) do
      WeatherSync.stub(:from_app_config, nil) { WeatherCurrentJob.perform_now }
    end
    assert_empty calls
  end
end
