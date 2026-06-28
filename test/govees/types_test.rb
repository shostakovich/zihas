# test/govees/types_test.rb
require "test_helper"
require "govees/types"

class GoveesTypesTest < ActiveSupport::TestCase
  test "Bool coerces on/off and 0/1" do
    assert_equal true,  Govees::Types::Bool["on"]
    assert_equal false, Govees::Types::Bool["off"]
    assert_equal true,  Govees::Types::Bool["1"]
    assert_equal false, Govees::Types::Bool[false]
  end

  test "Brightness is liberal 0..100 (device may report 0)" do
    assert_equal 0,  Govees::Types::Brightness["0"]
    assert_equal 100, Govees::Types::Brightness[100]
    assert_raises(Dry::Types::ConstraintError) { Govees::Types::Brightness["101"] }
  end

  test "Kelvin allows 0 (no slider lower bound on the wire)" do
    assert_equal 0,    Govees::Types::Kelvin[0]
    assert_equal 9000, Govees::Types::Kelvin["9000"]
    assert_raises(Dry::Types::ConstraintError) { Govees::Types::Kelvin["-1"] }
  end

  test "RgbComponent enforces 0..255" do
    assert_equal 255, Govees::Types::RgbComponent["255"]
    assert_raises(Dry::Types::ConstraintError) { Govees::Types::RgbComponent["256"] }
  end

  test "SceneName and ZoneName reject empty strings" do
    assert_equal "Sunset", Govees::Types::SceneName["Sunset"]
    assert_raises(Dry::Types::ConstraintError) { Govees::Types::ZoneName[""] }
  end
end
