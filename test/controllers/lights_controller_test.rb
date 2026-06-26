# test/controllers/lights_controller_test.rb
require "test_helper"

class LightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    Room.delete_all
  end

  test "index lists lights" do
    Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60001")
    get lights_url
    assert_response :success
    assert_match "Stehlampe", @response.body
  end

  test "update edits a light's name and room by key" do
    room  = Room.create!(name: "Wohnzimmer")
    light = Light.create!(name: "Lampe", key: "A1B2C3D4E5F60002")
    patch light_url(light), params: { light: { name: "Stehlampe", room_id: room.id } }
    assert_redirected_to lights_url
    light.reload
    assert_equal "Stehlampe", light.name
    assert_equal room, light.room
  end

  test "destroy removes a light" do
    light = Light.create!(name: "Weg", key: "A1B2C3D4E5F60003")
    assert_difference -> { Light.count }, -1 do
      delete light_url(light)
    end
  end

  test "there is no manual create route" do
    assert_raises(NameError) { new_light_path }
  end

  test "show renders the detail page for a light by key" do
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe",
                           supports_color: true, supports_color_temp: true)
    LightState.record_state(@light.key, on: true, brightness: 60, color_temp_k: 2700)
    get light_url(@light.key)
    assert_response :success
    assert_match "Wohnzimmer Stehlampe", @response.body
    assert_select "[data-controller='light-detail']"
    assert_select "[data-light-detail-key-value=?]", @light.key
  end

  test "show 404s for unknown key" do
    get light_url("NOPE")
    assert_response :not_found
  end

  test "show has hero, brightness, white slider and tabs" do
    @light = Light.create!(key: "ABCDEF01", name: "Wohnzimmer Stehlampe",
                           supports_color: true, supports_color_temp: true)
    LightState.record_state(@light.key, on: true, brightness: 60, color_temp_k: 2700)
    get light_url(@light.key)
    assert_response :success
    assert_select "button[data-action='light-detail#on']"
    assert_select "input[type=range][data-light-detail-target='brightness']"
    assert_select "input[type=range][data-light-detail-target='temp'][min='2700'][max='6500']"
    assert_select "button[data-light-detail-tab-param='white']"
    assert_select "button[data-light-detail-tab-param='color']"
  end

  test "show hides colour tab when the light has no colour support" do
    @light = Light.create!(key: "ABCDEF02", name: "Weißlampe",
                           supports_color: false, supports_color_temp: true)
    LightState.record_state(@light.key, on: true, brightness: 60, color_temp_k: 2700)
    get light_url(@light.key)
    assert_select "button[data-light-detail-tab-param='color']", count: 0
  end

  test "show uses namespaced Stimulus action params" do
    @light = Light.create!(key: "ABCDEF03", name: "Farblampe",
                           supports_color: true, supports_color_temp: true)
    LightState.record_state(@light.key, on: true, brightness: 80, color_r: 255, color_g: 107, color_b: 61)
    get light_url(@light.key)
    assert_response :success
    assert_select "button[data-light-detail-tab-param='white']"
    assert_select "button[data-light-detail-temp-param='2700']"
    assert_select "button[data-light-detail-color-param]"
  end

  test "scenes tab renders the curated Stimmungen" do
    light = Light.create!(key: "ABCDEF04", name: "Decke")
    get light_url(light.key)
    assert_select "button[data-action='light-detail#mood'][data-light-detail-mood-param='reading']"
    assert_select "button[data-light-detail-mood-param='party']"
  end

  test "scenes tab renders the device firmware scenes when present" do
    light = Light.create!(key: "ABCDEF05", name: "Decke", firmware_scenes: %w[Forest Aurora])
    get light_url(light.key)
    assert_select "button[data-action='light-detail#scene'][data-light-detail-scene-param='Forest']"
    assert_select "button[data-light-detail-scene-param='Aurora']"
  end

  test "scenes tab omits the Govee section when the light has no scenes" do
    light = Light.create!(key: "ABCDEF06", name: "Decke", firmware_scenes: [])
    get light_url(light.key)
    assert_select "button[data-action='light-detail#scene']", count: 0
  end

  test "detail hero lamp carries the per-SKU plush class" do
    light = Light.create!(key: "ABCDEF07", name: "Decke", sku: "H60A6")
    get light_url(light.key)
    assert_select ".ld-lamp.plush-ceiling"
  end
end
