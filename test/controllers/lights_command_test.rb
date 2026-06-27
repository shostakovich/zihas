# test/controllers/lights_command_test.rb
require "test_helper"

class LightsCommandTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    @light = Light.create!(name: "Stehlampe", key: "A1B2C3D4E5F60030")
    @calls = []
  end

  test "unknown light returns 404" do
    post light_command_url(light_key: "nope"), params: { command: "turn", on: "true" }
    assert_response :not_found
  end

  test "invalid command returns 422" do
    post light_command_url(light_key: @light.key), params: { command: "explode" }
    assert_response :unprocessable_entity
  end

  test "turn calls Govees::Commander and responds 202" do
    Govees::Commander.stub :turn, ->(l, **kw) { @calls << [ l.key, kw[:on] ] } do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :success
    assert_equal [ [ "A1B2C3D4E5F60030", true ] ], @calls
  end

  test "brightness forwards the integer value" do
    Govees::Commander.stub :set_brightness, ->(l, **kw) { @calls << kw[:value] } do
      post light_command_url(light_key: @light.key), params: { command: "brightness", value: "42" }
    end
    assert_response :no_content
    assert_equal [ 42 ], @calls
  end

  test "brightness responds 204 no_content for fire-and-forget" do
    @light = Light.create!(name: "L", key: "S3", zones: [])
    Govees::Commander.stub(:set_brightness, ->(*, **) { }) do
      post light_command_url(light_key: "S3"), params: { command: "brightness", value: "42" }
    end
    assert_response :no_content
  end

  test "effect forwards the scene name" do
    Govees::Commander.stub :set_scene, ->(l, **kw) { @calls << [ l.key, kw[:scene] ] } do
      post light_command_url(light_key: @light.key), params: { command: "effect", effect: "Forest" }
    end
    assert_response :no_content
    assert_equal [ [ "A1B2C3D4E5F60030", "Forest" ] ], @calls
  end

  test "broker failure responds 503" do
    failing = ->(*, **) { raise Govees::Commander::Error, "broker down" }
    Govees::Commander.stub :turn, failing do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :service_unavailable
  end

  test "zone command toggles a valid zone" do
    light = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, **) {
      assert_equal "rippleLightToggle", zone
      assert_equal true, on
    }) do
      post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "rippleLightToggle", on: "true" }
    end
    assert_response :success
  end

  test "zone command rejects a zone not on this light" do
    Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle])
    post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "powerSwitch", on: "true" }
    assert_response :unprocessable_entity
  end

  test "turning on a side zone over the limit evicts an on side and shows a toast" do
    light = Light.create!(name: "Up", key: "UP3", sku: "H60B0",
                          zones: %w[bottomLightToggle rippleLightToggle sideLightToggle])
    LightState.record_zone_state("UP3", "bottomLightToggle", true) # Haupt an
    LightState.record_zone_state("UP3", "rippleLightToggle", true) # eine Seite an -> 2 an == Limit
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, **) { calls << [ zone, on ] }) do
      post light_command_url(light_key: "UP3"),
           params: { command: "zone", zone: "sideLightToggle", on: "true" }, as: :turbo_stream
    end
    assert_response :success
    state = LightState.find_by(light_key: "UP3")
    assert_equal false, state.zone_states["rippleLightToggle"], "old side switched off"
    assert_equal true,  state.zone_states["sideLightToggle"],   "new side switched on"
    assert_equal true,  state.zone_states["bottomLightToggle"], "main untouched"
    assert_includes calls, [ "rippleLightToggle", false ]
    assert_includes calls, [ "sideLightToggle", true ]
    assert_select "turbo-stream[action=replace][target=zone_rippleLightToggle]"
    assert_select "turbo-stream[action=replace][target=zone_sideLightToggle]"
    assert_select "turbo-stream[action=replace][target=light_toast]"
  end

  test "turn optimistically persists on and replaces the power partial" do
    @light = Light.create!(name: "Lampe", key: "S2", zones: [])
    Govees::Commander.stub(:turn, ->(*, **) { }) do
      post light_command_url(light_key: "S2"),
           params: { command: "turn", on: "true" }, as: :turbo_stream
    end
    assert_response :success
    assert_equal true, LightState.find_by(light_key: "S2").on
    assert_select "turbo-stream[action=replace][target=light_power]"
  end

  test "turn also replaces the switches list card so /switches updates without JS" do
    @light = Light.create!(name: "Lampe", key: "S9", zones: [])
    Govees::Commander.stub(:turn, ->(*, **) { }) do
      post light_command_url(light_key: "S9"),
           params: { command: "turn", on: "true" }, as: :turbo_stream
    end
    assert_response :success
    assert_select "turbo-stream[action=replace][target=light_card_S9]"
  end

  test "zone_undo restores the victim, turns off the added zone and clears the toast" do
    light = Light.create!(name: "Up", key: "UP4", zones: %w[rippleLightToggle sideLightToggle])
    LightState.record_zone_state("UP4", "sideLightToggle", true)
    calls = []
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, **) { calls << [ zone, on ] }) do
      post light_command_url(light_key: "UP4"),
           params: { command: "zone_undo", victim: "rippleLightToggle", added: "sideLightToggle" },
           as: :turbo_stream
    end
    assert_response :success
    state = LightState.find_by(light_key: "UP4")
    assert_equal true,  state.zone_states["rippleLightToggle"]
    assert_equal false, state.zone_states["sideLightToggle"]
    assert_includes calls, [ "rippleLightToggle", true ]
    assert_includes calls, [ "sideLightToggle", false ]
    assert_select "turbo-stream[action=replace][target=light_toast]"
  end

  test "zone command responds with a turbo stream replacing the card" do
    Light.create!(name: "Up", key: "UP2", zones: %w[bottomLightToggle rippleLightToggle])
    Govees::Commander.stub(:set_zone, ->(*, **) { }) do
      post light_command_url(light_key: "UP2"),
           params: { command: "zone", zone: "rippleLightToggle", on: "true" },
           as: :turbo_stream
    end
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", @response.media_type
    assert_select "turbo-stream[action=replace][target=zone_rippleLightToggle]"
  end

  test "zone command persists the zone state" do
    Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
    Govees::Commander.stub(:set_zone, ->(*, **) { }) do
      post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "rippleLightToggle", on: "true" }
    end
    assert_response :success
    assert_equal({ "rippleLightToggle" => true }, LightState.find_by(light_key: "UP1").zone_states)
  end

  test "turn routes a zone lamp through powerSwitch" do
    light = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle sideLightToggle])
    called = {}
    Govees::Commander.stub(:set_zone, ->(l, zone:, on:, **) { called[:zone] = zone; called[:on] = on }) do
      post light_command_url(light_key: "UP1"), params: { command: "turn", on: "true" }
    end
    assert_equal "powerSwitch", called[:zone]
    assert_equal true, called[:on]
    assert_response :success
  end

  test "turn still uses the light command for a simple lamp" do
    Light.create!(name: "Lamp", key: "S1", zones: [])
    called = false
    Govees::Commander.stub(:turn, ->(l, on:, **) { called = true }) do
      post light_command_url(light_key: "S1"), params: { command: "turn", on: "false" }
    end
    assert called, "simple lamp uses Govees::Commander.turn"
    assert_response :success
  end
end
