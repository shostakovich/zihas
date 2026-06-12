require "test_helper"

class RackAttackTest < ActionDispatch::IntegrationTest
  test "throttle rules are registered" do
    names = Rack::Attack.throttles.keys
    assert_includes names, "api/ip"
    assert_includes names, "switch/ip"
  end
end
