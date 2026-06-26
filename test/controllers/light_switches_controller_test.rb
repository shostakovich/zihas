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

  test "broker failure responds 503" do
    failing = ->(*, **) { raise GoveeCommander::Error, "broker down" }
    GoveeCommander.stub :turn, failing do
      post light_command_url(light_key: @light.key), params: { command: "turn", on: "true" }
    end
    assert_response :service_unavailable
  end
end
