require "test_helper"

class SwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    SwitchWindow.delete_all
    PlugState.delete_all
    SwitchCommand.delete_all
    Sample.delete_all
  end

  test "GET /switches lists only switchable plugs" do
    get "/switches"
    assert_response :success
    assert_match "Kühlschrank", @response.body       # fridge: switchable in ziwoas.test.yml
    assert_no_match(/Balkonkraftwerk/, @response.body)  # bkw: producer, not switchable
  end

  test "shows the plug's windows" do
    SwitchWindow.create!(plug_id: "fridge", on_at: 1080, off_at: 1380, days: [ 1, 2, 3, 4, 5 ])
    get "/switches"
    assert_match "Mo–Fr · 18:00–23:00", @response.body
  end

  test "lists orphaned windows with delete option" do
    SwitchWindow.create!(plug_id: "gone", on_at: 60, off_at: 120, days: [ 1 ])
    get "/switches"
    assert_match "Verwaiste Zeitfenster", @response.body
    assert_match "gone", @response.body
  end

  test "no orphan section without orphans" do
    get "/switches"
    assert_no_match(/Verwaiste Zeitfenster/, @response.body)
  end
end
