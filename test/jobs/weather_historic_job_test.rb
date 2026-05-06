require "test_helper"

class WeatherHistoricJobTest < ActiveJob::TestCase
  test "syncs yesterday and backfills daily totals" do
    sync = Minitest::Mock.new
    sync.expect(:sync_historic_date, nil, [ Date.new(2026, 5, 3) ])
    sync.expect(:backfill_historic_from_daily_totals, nil)
    WeatherBroadcaster.stub(:broadcast_today, nil) do
      WeatherSync.stub(:from_app_config, sync) { WeatherHistoricJob.perform_now(today: Date.new(2026, 5, 4)) }
    end
    assert sync.verify
  end

  test "broadcasts today frame after backfill" do
    sync = Minitest::Mock.new
    sync.expect(:sync_historic_date, nil, [ Date.new(2026, 5, 3) ])
    sync.expect(:backfill_historic_from_daily_totals, nil)
    calls = []
    WeatherBroadcaster.stub(:broadcast_today, -> { calls << :today }) do
      WeatherSync.stub(:from_app_config, sync) { WeatherHistoricJob.perform_now(today: Date.new(2026, 5, 4)) }
    end
    assert_equal [ :today ], calls
  end
end
