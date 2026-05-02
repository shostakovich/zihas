require "mqtt"
require "json"
require "fritz_dect_client"

class FritzMqttBridge
  def initialize(fritz_client:, plug:, mqtt_config:, fritz_poll_cfg:, logger:,
                 mqtt_factory: nil)
    @fritz_client   = fritz_client
    @plug           = plug
    @mqtt_config    = mqtt_config
    @fritz_poll_cfg = fritz_poll_cfg
    @logger         = logger
    @stopping       = false
    @last_apower_w  = 0.0
    @mqtt_factory   = mqtt_factory || -> {
      MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    }
  end

  def run
    mqtt = @mqtt_factory.call
    mqtt.connect
    until @stopping
      poll_and_publish(mqtt)
      sleep_interruptible(interval)
    end
  ensure
    begin; mqtt&.disconnect; rescue StandardError; nil; end
  end

  def stop!
    @stopping = true
  end

  def poll_and_publish(mqtt)
    reading = @fritz_client.fetch(@plug)
    @last_apower_w = reading.apower_w
    payload = JSON.generate({ apower: reading.apower_w, aenergy: { total: reading.aenergy_wh } })
    mqtt.publish("#{@mqtt_config.topic_prefix}/#{@plug.id}/status/switch:0", payload)
  rescue FritzDectClient::Error => e
    @logger.warn("FritzMqttBridge #{@plug.id}: #{e.message}")
  end

  def interval
    @last_apower_w > @fritz_poll_cfg.idle_threshold_w ?
      @fritz_poll_cfg.active_interval_seconds :
      @fritz_poll_cfg.idle_interval_seconds
  end

  private

  def sleep_interruptible(seconds)
    deadline = Time.now + seconds
    while Time.now < deadline && !@stopping
      sleep([ deadline - Time.now, 1 ].min)
    end
  end
end
