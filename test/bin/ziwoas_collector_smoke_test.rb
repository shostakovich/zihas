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

  test "collector guards the govee bridge behind a non-blank api_key check" do
    src = File.read(Rails.root.join("bin/ziwoas_collector"))
    assert_includes src, "config.govee.api_key.present?",
      "expected an api_key presence guard before starting the Govee bridge"
  end

  test "collector warns when govee section is present but api_key is blank" do
    src = File.read(Rails.root.join("bin/ziwoas_collector"))
    assert_includes src, "Govees bridge disabled: missing govee.api_key in ziwoas.yml",
      "expected a logger.warn when govee config exists but api_key is blank"
  end
end
