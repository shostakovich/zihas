require "test_helper"

class SampleTest < ActiveSupport::TestCase
  def valid_sample
    Sample.new(plug_id: "bkw", ts: 1_700_000_000, apower_w: 100.0, aenergy_wh: 500.0)
  end

  test "valid sample is valid" do
    assert valid_sample.valid?
  end

  test "plug_id is required" do
    s = valid_sample
    s.plug_id = nil
    refute s.valid?
    assert_includes s.errors[:plug_id], "can't be blank"
  end

  test "ts must be a positive integer" do
    s = valid_sample
    s.ts = -1
    refute s.valid?
  end

  test "ts is required" do
    s = valid_sample
    s.ts = nil
    refute s.valid?
  end

  test "apower_w is required" do
    s = valid_sample
    s.apower_w = nil
    refute s.valid?
  end

  test "aenergy_wh is required" do
    s = valid_sample
    s.aenergy_wh = nil
    refute s.valid?
  end
end
