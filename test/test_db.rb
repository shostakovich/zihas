require "test_helper"
require "db"

class DbTest < Minitest::Test
  def setup
    @db = DB.connect(":memory:")
    DB.migrate!(@db)
  end

  def test_samples_schema
    @db[:samples].insert(plug_id: "bkw", ts: 1_700_000_000, apower_w: 300.5, aenergy_wh: 12_345.6)
    row = @db[:samples].first
    assert_equal "bkw", row[:plug_id]
    assert_equal 1_700_000_000, row[:ts]
    assert_in_delta 300.5, row[:apower_w]
  end

  def test_samples_composite_primary_key_prevents_duplicates
    @db[:samples].insert(plug_id: "bkw", ts: 100, apower_w: 1, aenergy_wh: 1)
    assert_raises(Sequel::UniqueConstraintViolation) do
      @db[:samples].insert(plug_id: "bkw", ts: 100, apower_w: 2, aenergy_wh: 2)
    end
  end

  def test_samples_5min_schema
    @db[:samples_5min].insert(
      plug_id: "bkw", bucket_ts: 1_700_000_000,
      avg_power_w: 250.0, energy_delta_wh: 20.8, sample_count: 60
    )
    assert_equal 1, @db[:samples_5min].count
  end

  def test_daily_totals_schema
    @db[:daily_totals].insert(plug_id: "bkw", date: "2026-04-13", energy_wh: 1240.5)
    assert_in_delta 1240.5, @db[:daily_totals].first[:energy_wh]
  end

  def test_migrate_is_idempotent
    DB.migrate!(@db)  # second call should not raise
    DB.migrate!(@db)  # third too
    assert true
  end
end
