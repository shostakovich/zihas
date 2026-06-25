require "mqtt"

# One MQTT connection that subscribes to the union of all handler patterns and
# dispatches each message to the handler whose #matches? returns true.
# Backoff/reconnect loop lives here (extracted from the former MqttSubscriber).
class MqttRouter
  def initialize(mqtt_config:, handlers:, logger:)
    @mqtt_config = mqtt_config
    @handlers    = handlers
    @logger      = logger
    @stopping    = false
  end

  def run
    backoff = 1
    until @stopping
      begin
        connect_and_run
        backoff = 1
      rescue => e
        @logger.error("MqttRouter: #{e.class}: #{e.message}")
        sleep([ backoff, 60 ].min) unless @stopping
        backoff = [ backoff * 2, 60 ].min
      end
    end
  end

  def stop!
    @stopping = true
    begin; @client&.disconnect; rescue StandardError; nil; end
  end

  def dispatch(topic, payload)
    handler = @handlers.find { |h| h.matches?(topic) }
    return @logger.warn("MqttRouter: no handler for #{topic}") unless handler
    handler.handle(topic, payload)
  end

  private

  def connect_and_run
    @client = MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    @client.connect
    topics = @handlers.flat_map(&:subscriptions).uniq
    topics.each { |t| @client.subscribe(t) }
    @logger.info("MqttRouter: connected to #{@mqtt_config.host}:#{@mqtt_config.port}, subscribed #{topics.join(', ')}")
    @client.get { |t, payload| dispatch(t, payload) }
  ensure
    begin; @client&.disconnect; rescue StandardError; nil; end
  end
end
