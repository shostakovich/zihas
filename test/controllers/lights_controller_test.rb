# test/controllers/lights_controller_test.rb
require "test_helper"

class LightsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Light.delete_all
    Room.delete_all
  end

  test "index lists lights" do
    Light.create!(name: "Stehlampe", ip_address: "192.168.10.20")
    get lights_url
    assert_response :success
    assert_match "Stehlampe", @response.body
  end

  test "create adds a light, generates a key, redirects" do
    room = Room.create!(name: "Wohnzimmer")
    assert_difference -> { Light.count }, 1 do
      post lights_url, params: { light: { name: "Neue Lampe", room_id: room.id, ip_address: "192.168.10.30" } }
    end
    assert_redirected_to lights_url
    assert_equal "neue_lampe", Light.last.key
  end

  test "create rejects a blank ip" do
    assert_no_difference -> { Light.count } do
      post lights_url, params: { light: { name: "X", ip_address: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "update edits a light by key" do
    light = Light.create!(name: "Lampe", ip_address: "192.168.10.31")
    patch light_url(light), params: { light: { ip_address: "192.168.10.99" } }
    assert_equal "192.168.10.99", light.reload.ip_address
  end

  test "destroy removes a light" do
    light = Light.create!(name: "Weg", ip_address: "192.168.10.32")
    assert_difference -> { Light.count }, -1 do
      delete light_url(light)
    end
  end

  test "test_connection publishes a refresh command and redirects" do
    light = Light.create!(name: "Lampe", ip_address: "192.168.10.33")
    calls = []
    GoveeCommander.stub :refresh, ->(l, **) { calls << l.key } do
      post test_connection_light_url(light)
    end
    assert_equal [ "lampe" ], calls
    assert_redirected_to lights_url
  end
end
