require "test_helper"

class LoadEstimateTest < ActiveSupport::TestCase
  test "effective_w prefers live consumption" do
    est = LoadEstimate.new(current_w: 240.0, floor_w: 85.0)
    assert_in_delta 240.0, est.effective_w, 0.001
  end

  test "effective_w caps live consumption at the median" do
    est = LoadEstimate.new(current_w: 800.0, floor_w: 85.0, median_w: 240.0)
    assert_in_delta 240.0, est.effective_w, 0.001
  end

  test "effective_w follows live consumption down below the median" do
    est = LoadEstimate.new(current_w: 120.0, floor_w: 85.0, median_w: 240.0)
    assert_in_delta 120.0, est.effective_w, 0.001
  end

  test "effective_w uses live consumption when median is missing" do
    est = LoadEstimate.new(current_w: 240.0, floor_w: 85.0, median_w: nil)
    assert_in_delta 240.0, est.effective_w, 0.001
  end

  test "effective_w falls back to floor when live load is nil" do
    est = LoadEstimate.new(current_w: nil, floor_w: 85.0, median_w: 240.0)
    assert_in_delta 85.0, est.effective_w, 0.001
  end
end
