require "test_helper"

class LightsHelperTest < ActionView::TestCase
  test "scene_gradient is deterministic for a given name" do
    assert_equal scene_gradient("Forest"), scene_gradient("Forest")
  end

  test "scene_gradient differs for different names and is a linear-gradient" do
    assert scene_gradient("Forest").start_with?("linear-gradient")
    refute_equal scene_gradient("Forest"), scene_gradient("Aurora")
  end
end
