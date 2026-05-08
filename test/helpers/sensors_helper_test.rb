# test/helpers/sensors_helper_test.rb
require "test_helper"

class SensorsHelperTest < ActionView::TestCase
  include SensorsHelper

  test "co2_level returns :good below 1000 ppm" do
    assert_equal :good, co2_level(0)
    assert_equal :good, co2_level(999)
  end

  test "co2_level returns :warn between 1000 and 1400" do
    assert_equal :warn, co2_level(1000)
    assert_equal :warn, co2_level(1400)
  end

  test "co2_level returns :bad above 1400" do
    assert_equal :bad, co2_level(1401)
    assert_equal :bad, co2_level(9999)
  end

  test "co2_level returns nil for nil input" do
    assert_nil co2_level(nil)
  end

  test "co2_icon_path maps level to asset filename" do
    assert_equal "co2_good.webp", co2_icon_path(:good)
    assert_equal "co2_warn.webp", co2_icon_path(:warn)
    assert_equal "co2_bad.webp",  co2_icon_path(:bad)
  end

  test "battery_low? returns true at or below 20" do
    assert battery_low?(19)
    assert battery_low?(20)
    refute battery_low?(21)
    refute battery_low?(nil)
  end
end
