require "test_helper"
require "tmpdir"

class AggregatorJobTest < ActiveJob::TestCase
  self.use_transactional_tests = false

  setup do
    Sample.delete_all
    Sample5min.delete_all
    DailyTotal.delete_all
  end

  test "aggregates finished days and writes a backup" do
    tz = TZInfo::Timezone.get("Europe/Berlin")
    start_ts = tz.local_to_utc(Time.parse("2026-04-10 00:00:00")).to_i

    Sample.create!(plug_id: "bkw", ts: start_ts, apower_w: 10, aenergy_wh: 100)
    Sample.create!(plug_id: "bkw", ts: start_ts + 3600, apower_w: 10, aenergy_wh: 150)

    Dir.mktmpdir do |backup_dir|
      AggregatorJob.perform_now(today: Date.new(2026, 4, 11), backup_dir: backup_dir)

      total = DailyTotal.find_by!(plug_id: "bkw", date: "2026-04-10")
      assert_in_delta 50.0, total.energy_wh
      assert_equal 1, Dir.glob("#{backup_dir}/ziwoas-*.db").length
    end
  end
end
