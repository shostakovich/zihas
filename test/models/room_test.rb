require "test_helper"

class RoomTest < ActiveSupport::TestCase
  test "valid with a name" do
    assert Room.new(name: "Wohnzimmer").valid?
  end

  test "requires a name" do
    refute Room.new(name: "").valid?
  end

  test "name is unique" do
    Room.create!(name: "Küche")
    refute Room.new(name: "Küche").valid?
  end
end
