require "test_helper"

class SwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    SwitchWindow.delete_all
    PlugState.delete_all
    SwitchCommand.delete_all
    Sample.delete_all
    Light.delete_all
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe")
    LightState.record_state(@light.key, on: true, brightness: 60, color_temp_k: 2700)
  end

  test "lamp tile links to the detail page and exposes a toggle knob" do
    get switches_url
    assert_response :success
    assert_select "a.sw-light-link[href=?]", light_path(@light.key)
    assert_select ".sw-light-card[data-light-key=?] button.sw-knob", @light.key
    assert_match "Wohnzimmer Stehlampe", @response.body
    assert_match "An · Weiß · 60 %", @response.body
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
