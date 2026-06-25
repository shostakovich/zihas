# test/controllers/rooms_controller_test.rb
require "test_helper"

class RoomsControllerTest < ActionDispatch::IntegrationTest
  setup { Room.delete_all }

  test "index lists rooms" do
    Room.create!(name: "Wohnzimmer")
    get rooms_url
    assert_response :success
    assert_match "Wohnzimmer", @response.body
  end

  test "create adds a room and redirects" do
    assert_difference -> { Room.count }, 1 do
      post rooms_url, params: { room: { name: "Küche" } }
    end
    assert_redirected_to rooms_url
  end

  test "create rejects a blank name" do
    assert_no_difference -> { Room.count } do
      post rooms_url, params: { room: { name: "" } }
    end
    assert_response :unprocessable_entity
  end

  test "update renames a room" do
    room = Room.create!(name: "Alt")
    patch room_url(room), params: { room: { name: "Neu" } }
    assert_equal "Neu", room.reload.name
  end

  test "destroy removes a room" do
    room = Room.create!(name: "Weg")
    assert_difference -> { Room.count }, -1 do
      delete room_url(room)
    end
  end
end
