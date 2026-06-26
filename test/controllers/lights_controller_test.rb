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
end
