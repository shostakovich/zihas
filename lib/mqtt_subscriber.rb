require "mqtt"
require "json"

class MqttSubscriber
  def initialize(mqtt_config:, plugs:, logger:, clock: -> { Time.now.to_f })
    @mqtt_config  = mqtt_config
    @plug_map     = plugs.to_h { |p| [p.id, p] }
    @logger       = logger
    @clock        = clock
    @stopping     = false
    @buckets      = {}
    @last_power_w = {}
  end

  def run
    backoff = 1
    until @stopping
      begin
        connect_and_run
        backoff = 1
      rescue => e
        @logger.error("MqttSubscriber: #{e.class}: #{e.message}")
        sleep([backoff, 60].min) unless @stopping
        backoff = [backoff * 2, 60].min
      end
    end
  end

  def stop!
    @stopping = true
    begin; @client&.disconnect; rescue StandardError; nil; end
  end

  def handle_message(topic, payload)
    plug_id = topic.split("/")[@mqtt_config.topic_prefix.split("/").length]
    plug    = @plug_map[plug_id]
    unless plug
      @logger.warn("MqttSubscriber: unknown plug '#{plug_id}' on topic #{topic}")
      return
    end

    data       = JSON.parse(payload)
    apower_w   = data["apower"].to_f
    aenergy_wh = data.dig("aenergy", "total").to_f
    ts         = @clock.call.to_i

    Sample.create!(plug_id: plug_id, ts: ts, apower_w: apower_w, aenergy_wh: aenergy_wh)
    @logger.debug("MqttSubscriber: #{plug_id} #{apower_w} W / #{aenergy_wh} Wh")
    broadcast_if_changed(plug, ts, apower_w, aenergy_wh)
  rescue ActiveRecord::RecordNotUnique
    # duplicate ts within same second — skip silently
  rescue JSON::ParserError => e
    @logger.warn("MqttSubscriber: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def connect_and_run
    @client = MQTT::Client.new(host: @mqtt_config.host, port: @mqtt_config.port)
    @client.connect
    topic = "#{@mqtt_config.topic_prefix}/+/status/switch:0"
    @client.subscribe(topic)
    @logger.info("MqttSubscriber: connected to #{@mqtt_config.host}:#{@mqtt_config.port}, subscribed #{topic}")
    @client.get { |t, payload| handle_message(t, payload) }
  ensure
    begin; @client&.disconnect; rescue StandardError; nil; end
  end

  def broadcast_if_changed(plug, ts, apower_w, aenergy_wh)
    display_power = (plug.role == :producer ? apower_w.abs : apower_w).round
    return if @last_power_w[plug.id] == display_power

    @last_power_w[plug.id] = display_power

    bucket_ts = (ts / 60) * 60
    bucket    = @buckets[plug.id]
    if bucket && bucket[:bucket_ts] == bucket_ts
      bucket[:sum]   += apower_w
      bucket[:count] += 1
    else
      @buckets[plug.id] = { bucket_ts: bucket_ts, sum: apower_w, count: 1 }
      bucket = @buckets[plug.id]
    end
    avg_power_w = bucket[:sum].to_f / bucket[:count]

    ActionCable.server.broadcast("dashboard", {
      ts:    ts,
      plugs: [{
        plug_id:     plug.id,
        name:        plug.name,
        role:        plug.role.to_s,
        online:      true,
        ts:          ts,
        bucket_ts:   bucket_ts,
        apower_w:    apower_w,
        avg_power_w: avg_power_w,
        aenergy_wh:  aenergy_wh,
      }]
    })
  rescue => e
    @logger.warn("MqttSubscriber: ActionCable broadcast failed: #{e.message}")
  end
end
