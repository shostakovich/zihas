# test/controllers/lights_controller_test.rb
require "test_helper"

class LightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
  end

  test "index lists lights" do
    Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60001")
    get lights_url
    assert_response :success
    assert_match "Stehlampe", @response.body
  end

  test "update edits a light's name by key" do
    light = Light.create!(name: "Lampe", key: "A1B2C3D4E5F60002")
    patch light_url(light), params: { light: { name: "Stehlampe" } }
    assert_redirected_to lights_url
    light.reload
    assert_equal "Stehlampe", light.name
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
    assert_select "#light_power .ld-pill"
    assert_select "input[type=range][data-action='light-detail#brightness']"
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

  test "scenes tab renders the device firmware scenes when present" do
    light = Light.create!(key: "ABCDEF05", name: "Decke", firmware_scenes: %w[Forest Aurora])
    get light_url(light.key)
    assert_select "form.ld-inline-form input[name='effect'][value='Forest']"
    assert_select "form.ld-inline-form input[name='effect'][value='Aurora']"
  end

  test "scenes tab shows a hint instead of buttons when the light has no scenes" do
    light = Light.create!(key: "ABCDEF06", name: "Decke", firmware_scenes: [])
    get light_url(light.key)
    assert_select "form.ld-inline-form input[name='effect']", count: 0
    assert_select ".ld-panel[data-tab=scenes] .ld-zone-hint", text: "Diese Lampe meldet keine Govee-Szenen."
  end

  test "detail hero lamp carries the per-SKU plush class" do
    light = Light.create!(key: "ABCDEF07", name: "Decke", sku: "H60A6")
    get light_url(light.key)
    assert_select ".ld-lamp.plush-ceiling"
  end

  test "zone lamp renders one toggle button per zone inside the hero, no Zonen tab" do
    Light.create!(name: "Up", key: "UP1", sku: "H60B0",
                  zones: %w[bottomLightToggle sideLightToggle rippleLightToggle])
    get light_url(key: "UP1")
    assert_response :success
    # zones live in the hero tile now, not a tab/panel
    assert_select "button.ld-tab[data-light-detail-tab-param=zones]", false
    assert_select ".ld-panel[data-tab=zones]", false
    assert_select "#light_power .ld-zones-row .ld-zone-btn", 3
    # detail page always opens on the white tab
    assert_select ".ld[data-light-detail-tab-value=white]"
    assert_select "button.ld-tab[data-light-detail-tab-param=white]"
  end

  test "zone buttons are visible when the lamp is on, hidden when off" do
    Light.create!(name: "Up", key: "UPVIS", sku: "H60B0",
                  zones: %w[bottomLightToggle sideLightToggle])
    # off (no state) -> zones row carries the is-off hide marker
    get light_url(key: "UPVIS")
    assert_select ".ld-zones-row.is-off"
    # on -> no hide marker
    LightState.record_state("UPVIS", on: true)
    get light_url(key: "UPVIS")
    assert_select ".ld-zones-row:not(.is-off)"
  end

  test "simple lamp renders no zone buttons" do
    Light.create!(name: "Lamp", key: "S1", supports_color: true)
    get light_url(key: "S1")
    assert_select ".ld-zones-row", false
    assert_select ".ld-zone-btn", false
  end

  test "show renders a zone toggle with stable id and reflects persisted zone_states" do
    light = Light.create!(name: "Up", key: "UP9", zones: %w[bottomLightToggle rippleLightToggle])
    LightState.record_zone_state("UP9", "rippleLightToggle", true)
    get light_url(key: "UP9")
    assert_response :success
    assert_select "form#zone_rippleLightToggle .ld-zone-btn.on"
    assert_select "form#zone_bottomLightToggle .ld-zone-btn:not(.on)"
  end
end
