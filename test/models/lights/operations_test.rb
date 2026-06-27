# test/models/lights/operations_test.rb
require "test_helper"

class Lights::OperationsTest < ActiveSupport::TestCase
  test "maps command names to operation classes" do
    assert_equal Lights::Operations::Turn,          Lights::Operations["turn"]
    assert_equal Lights::Operations::SetZone,       Lights::Operations["zone"]
    assert_equal Lights::Operations::SetBrightness, Lights::Operations["brightness"]
    assert_equal Lights::Operations::SetColor,      Lights::Operations["color"]
    assert_equal Lights::Operations::SetColorTemp,  Lights::Operations["color_temp"]
    assert_equal Lights::Operations::SetScene,      Lights::Operations["effect"]
    assert_equal Lights::Operations::SetScene,      Lights::Operations["scene"]
    assert_equal Lights::Operations::UndoZone,      Lights::Operations["zone_undo"]
  end

  test "returns nil for an unknown command" do
    assert_nil Lights::Operations["explode"]
  end
end
