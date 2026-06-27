# frozen_string_literal: true

require "test_helper"

class ZiwoasCollectorSmokeTest < ActiveSupport::TestCase
  test "collector requires the govees subscriber and bridge, not the old govee handlers" do
    src = File.read(Rails.root.join("bin/ziwoas_collector"))
    assert_includes src, %(require "govees/subscriber")
    assert_includes src, %(require "govees/bridge")
    assert_includes src, "Govees::Subscriber.new"
    refute_includes src, %(require "govee_status_handler")
    refute_includes src, %(require "govee_zone_state_handler")
  end
end
