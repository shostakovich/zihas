require "test_helper"
require "energy_deltas"

class EnergyDeltasTest < ActiveSupport::TestCase
  test "cte sums plausible deltas and zeroes glitches" do
    Sample.create!(plug_id: "p1", ts: 1000, apower_w: 100, aenergy_wh: 50)
    Sample.create!(plug_id: "p1", ts: 1010, apower_w: 100, aenergy_wh: 51)        # +1 Wh plausible
    Sample.create!(plug_id: "p1", ts: 1020, apower_w: 100, aenergy_wh: 1_000_000) # glitch → 0
    sql = EnergyDeltas.cte + "SELECT SUM(delta_wh) AS total FROM deltas"
    rows = ActiveRecord::Base.connection.exec_query(
      ActiveRecord::Base.sanitize_sql_array([ sql, 0, 2000 ])
    )
    assert_in_delta 1.0, rows.first["total"], 0.001
  end
end
