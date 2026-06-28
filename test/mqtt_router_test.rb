require "test_helper"
require "mqtt_router"
require "config_loader"
require "logger"
require "stringio"

class MqttRouterTest < ActiveSupport::TestCase
  class FakeHandler
    attr_reader :handled
    def initialize(prefix) = (@prefix = prefix; @handled = [])
    def subscriptions = [ "#{@prefix}/#" ]
    def matches?(topic) = topic.start_with?("#{@prefix}/")
    def handle(topic, payload) = @handled << [ topic, payload ]
  end

  setup do
    @log_io = StringIO.new
    @logger = Logger.new(@log_io)
    @mqtt_config = ConfigLoader::MqttCfg.new(host: "localhost", port: 1883, topic_prefix: "shellies")
  end

  test "dispatch routes a topic to the matching handler" do
    shelly = FakeHandler.new("shellies")
    govee  = FakeHandler.new("govee")
    router = MqttRouter.new(mqtt_config: @mqtt_config, handlers: [ shelly, govee ], logger: @logger)

    router.dispatch("govee/lamp/status", "payload")

    assert_equal [], shelly.handled
    assert_equal [ [ "govee/lamp/status", "payload" ] ], govee.handled
  end

  test "dispatch warns when no handler matches" do
    router = MqttRouter.new(mqtt_config: @mqtt_config, handlers: [ FakeHandler.new("shellies") ], logger: @logger)
    router.dispatch("unknown/topic", "x")
    assert_match(/no handler/i, @log_io.string)
  end
end
