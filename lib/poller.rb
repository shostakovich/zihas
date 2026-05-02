require "shelly_client"
require "fritz_dect_client"
require "circuit_breaker"

class Poller
  def initialize(plugs:, clients:, logger:, breaker_opts:, clock: -> { Time.now.to_f })
    @plugs    = plugs
    @clients  = clients
    @logger   = logger
    @clock    = clock
    @breakers = plugs.to_h do |plug|
      [ plug.id, build_breaker(plug, breaker_opts) ]
    end
    @buckets  = {}   # plug_id => { bucket_ts:, sum:, count: }
    @last_broadcast_power_w = {}
    @stopping = false
  end

  def tick
    ts = @clock.call.to_i
    changed_readings = []

    @plugs.each do |plug|
      breaker = @breakers[plug.id]
      next if breaker.skip?

      begin
        reading = @clients[plug.id].fetch(plug)
        Sample.create!(
          plug_id:    plug.id,
          ts:         ts,
          apower_w:   reading.apower_w,
          aenergy_wh: reading.aenergy_wh,
        )
        breaker.record_success
        payload = reading_payload(plug, ts, reading)
        changed_readings << payload if should_broadcast?(plug, reading)
      rescue ShellyClient::Error, FritzDectClient::Error => e
        breaker.record_failure
        @logger.debug("plug #{plug.id} poll failed: #{e.message}")
      rescue ActiveRecord::RecordNotUnique
        # Duplicate ts (can happen on clock skew). Still broadcast last reading if we have it.
        if reading
          payload = reading_payload(plug, ts, reading)
          changed_readings << payload if should_broadcast?(plug, reading)
        end
      rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::ConnectionNotEstablished,
             ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid => e
        # DB not ready yet (pool not up, file missing, or schema not migrated) — skip and retry.
        @logger.warn("plug #{plug.id}: DB not ready (#{e.class}), skipping")
      end
    end

    broadcast_readings(ts, changed_readings)
  end

  def run(interval)
    until @stopping
      start = @clock.call
      tick
      elapsed  = @clock.call - start
      sleep_for = interval - elapsed
      sleep(sleep_for) if sleep_for.positive? && !@stopping
    end
  end

  def stop!
    @stopping = true
  end

  private

  def reading_payload(plug, ts, reading)
    bucket_ts = (ts / 60) * 60
    bucket    = @buckets[plug.id]

    if bucket && bucket[:bucket_ts] == bucket_ts
      bucket[:sum]   += reading.apower_w
      bucket[:count] += 1
    else
      @buckets[plug.id] = { bucket_ts: bucket_ts, sum: reading.apower_w, count: 1 }
      bucket = @buckets[plug.id]
    end

    avg_power_w = bucket[:sum].to_f / bucket[:count]

    {
      plug_id:     plug.id,
      name:        plug.name,
      role:        plug.role.to_s,
      online:      true,
      ts:          ts,
      bucket_ts:   bucket_ts,
      apower_w:    reading.apower_w,
      avg_power_w: avg_power_w,
      aenergy_wh:  reading.aenergy_wh
    }
  end

  def should_broadcast?(plug, reading)
    power_w = display_power_w(plug, reading).round
    return false if @last_broadcast_power_w[plug.id] == power_w

    @last_broadcast_power_w[plug.id] = power_w
    true
  end

  def display_power_w(plug, reading)
    plug.role.to_s == "producer" ? reading.apower_w.abs : reading.apower_w
  end

  def broadcast_readings(ts, readings)
    return if readings.empty?

    ActionCable.server.broadcast("dashboard", {
      ts: ts,
      plugs: readings
    })
  rescue => e
    @logger.warn("ActionCable broadcast failed (#{e.class}): #{e.message}")
  end

  def build_breaker(plug, opts)
    logger = @logger
    id     = plug.id
    CircuitBreaker.new(
      threshold:     opts[:threshold],
      probe_seconds: opts[:probe_seconds],
      clock:         @clock,
    ) do |from, to|
      if to == :open
        logger.warn("opening breaker for plug #{id} after consecutive failures")
      elsif to == :closed
        logger.info("plug #{id} recovered, closing breaker")
      end
    end
  end
end
