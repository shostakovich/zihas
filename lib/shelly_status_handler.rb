require "json"

# Consumes Shelly (and Fritz-via-bridge) status messages on the shellies topic:
# inserts Sample rows, records PlugState output, and batches a "dashboard"
# ActionCable broadcast. Extracted verbatim from the former MqttSubscriber.
class ShellyStatusHandler
  BROADCAST_INTERVAL = 5

  def initialize(mqtt_config:, plugs:, logger:, clock: -> { Time.now.to_f })
    @mqtt_config       = mqtt_config
    @plug_map          = plugs.to_h { |p| [ p.id, p ] }
    @logger            = logger
    @clock             = clock
    @buckets           = {}
    @pending           = {}
    @last_broadcast_at = 0
  end

  def subscriptions = [ "#{@mqtt_config.topic_prefix}/+/status/switch:0" ]

  def matches?(topic) = topic.start_with?("#{@mqtt_config.topic_prefix}/")

  def handle(topic, payload)
    plug_id = topic.split("/")[@mqtt_config.topic_prefix.split("/").length]
    plug    = @plug_map[plug_id]
    unless plug
      @logger.warn("ShellyStatusHandler: unknown plug '#{plug_id}' on topic #{topic}")
      return
    end

    data       = JSON.parse(payload)
    apower_w   = data["apower"].to_f
    aenergy_wh = data.dig("aenergy", "total").to_f
    output     = data["output"]
    ts         = @clock.call.to_i

    Sample.create!(plug_id: plug_id, ts: ts, apower_w: apower_w, aenergy_wh: aenergy_wh)
    PlugState.record_output(plug_id, output) unless output.nil?
    @logger.debug("ShellyStatusHandler: #{plug_id} #{apower_w} W / #{aenergy_wh} Wh")
    accumulate(plug, ts, apower_w, aenergy_wh, output)
  rescue ActiveRecord::RecordNotUnique
    # duplicate ts within same second — skip silently
  rescue ActiveRecord::RecordInvalid => e
    @logger.warn("ShellyStatusHandler: invalid output on #{topic}: #{e.message}")
  rescue JSON::ParserError => e
    @logger.warn("ShellyStatusHandler: invalid JSON on #{topic}: #{e.message}")
  end

  private

  def accumulate(plug, ts, apower_w, aenergy_wh, output = nil)
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

    @pending[plug.id] = {
      plug_id: plug.id, name: plug.name, role: plug.role.to_s, online: true,
      ts: ts, bucket_ts: bucket_ts, apower_w: apower_w, avg_power_w: avg_power_w,
      aenergy_wh: aenergy_wh, output: output
    }

    now = @clock.call
    return unless now - @last_broadcast_at >= BROADCAST_INTERVAL

    ActionCable.server.broadcast("dashboard", { ts: now.to_i, plugs: @pending.values })
    @pending.clear
    @last_broadcast_at = now
  rescue => e
    @logger.warn("ShellyStatusHandler: ActionCable broadcast failed: #{e.message}")
  end
end
