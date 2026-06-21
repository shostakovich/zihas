require "test_helper"

class SolakonControlStateTest < ActiveSupport::TestCase
  setup { SolakonControlState.delete_all if defined?(SolakonControlState) }

  test "current returns a singleton defaulting to active auto regulation" do
    state = SolakonControlState.current

    assert_equal state, SolakonControlState.current
    assert_equal false, state.auto_regulation_paused
    assert state.auto_regulation_active?
  end

  test "pause and resume change persistent runtime state" do
    state = SolakonControlState.current

    state.pause_auto_regulation!
    assert_not SolakonControlState.current.auto_regulation_active?

    state.resume_auto_regulation!
    assert SolakonControlState.current.auto_regulation_active?
  end
end
