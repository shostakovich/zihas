# test/controllers/light_switches_controller_test.rb
require "test_helper"

class LightSwitchesControllerTest < ActionDispatch::IntegrationTest
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

  test "turn calls GoveeCommander and responds 202" do
    GoveeCommander.stub :turn, ->(l, **kw) { @calls << [ l.key, kw[:on] ] } do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :accepted
    assert_equal [ [ "A1B2C3D4E5F60030", true ] ], @calls
  end

  test "brightness forwards the integer value" do
    GoveeCommander.stub :set_brightness, ->(l, **kw) { @calls << kw[:value] } do
      post light_command_url(light_key: @light.key), params: { command: "brightness", value: "42" }
    end
    assert_response :accepted
    assert_equal [ 42 ], @calls
  end

  test "effect forwards the scene name" do
    GoveeCommander.stub :set_effect, ->(l, **kw) { @calls << [ l.key, kw[:effect] ] } do
      post light_command_url(light_key: @light.key), params: { command: "effect", effect: "Forest" }
    end
    assert_response :accepted
    assert_equal [ [ "A1B2C3D4E5F60030", "Forest" ] ], @calls
  end

  test "mood applies turn, brightness and colour-temp for a white mood (reading)" do
    GoveeCommander.stub :turn, ->(l, **kw) { @calls << [ :turn, kw[:on] ] } do
      GoveeCommander.stub :set_brightness, ->(l, **kw) { @calls << [ :brightness, kw[:value] ] } do
        GoveeCommander.stub :set_color_temp, ->(l, **kw) { @calls << [ :temp, kw[:kelvin] ] } do
          post light_command_url(light_key: @light.key), params: { command: "mood", mood: "reading" }
        end
      end
    end
    assert_response :accepted
    assert_equal [ [ :turn, true ], [ :brightness, 80 ], [ :temp, 3000 ] ], @calls
  end

  test "mood applies colour for an rgb mood (sunset)" do
    GoveeCommander.stub :turn, ->(*, **) { } do
      GoveeCommander.stub :set_brightness, ->(*, **) { } do
        GoveeCommander.stub :set_color, ->(l, **kw) { @calls << [ kw[:r], kw[:g], kw[:b] ] } do
          post light_command_url(light_key: @light.key), params: { command: "mood", mood: "sunset" }
        end
      end
    end
    assert_response :accepted
    assert_equal [ [ 255, 122, 61 ] ], @calls
  end

  test "unknown mood returns 422" do
    post light_command_url(light_key: @light.key), params: { command: "mood", mood: "nope" }
    assert_response :unprocessable_entity
  end

  test "broker failure responds 503" do
    failing = ->(*, **) { raise GoveeCommander::Error, "broker down" }
    GoveeCommander.stub :turn, failing do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :service_unavailable
  end

  test "zone command toggles a valid zone" do
    light = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle rippleLightToggle])
    GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) {
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
    GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) { calls << [ zone, on ] }) do
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

  test "zone command responds with a turbo stream replacing the card" do
    Light.create!(name: "Up", key: "UP2", zones: %w[bottomLightToggle rippleLightToggle])
    GoveeCommander.stub(:set_zone, ->(*, **) {}) do
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
    GoveeCommander.stub(:set_zone, ->(*, **) {}) do
      post light_command_url(light_key: "UP1"), params: { command: "zone", zone: "rippleLightToggle", on: "true" }
    end
    assert_response :success
    assert_equal({ "rippleLightToggle" => true }, LightState.find_by(light_key: "UP1").zone_states)
  end

  test "turn routes a zone lamp through powerSwitch" do
    light = Light.create!(name: "Up", key: "UP1", zones: %w[bottomLightToggle sideLightToggle])
    called = {}
    GoveeCommander.stub(:set_zone, ->(l, zone:, on:, **) { called[:zone] = zone; called[:on] = on }) do
      post light_command_url(light_key: "UP1"), params: { command: "turn", on: "true" }
    end
    assert_equal "powerSwitch", called[:zone]
    assert_equal true, called[:on]
    assert_response :accepted
  end

  test "turn still uses the light command for a simple lamp" do
    Light.create!(name: "Lamp", key: "S1", zones: [])
    called = false
    GoveeCommander.stub(:turn, ->(l, on:, **) { called = true }) do
      post light_command_url(light_key: "S1"), params: { command: "turn", on: "false" }
    end
    assert called, "simple lamp uses GoveeCommander.turn"
    assert_response :accepted
  end
end
