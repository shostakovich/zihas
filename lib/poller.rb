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
      [plug.id, build_breaker(plug, breaker_opts)]
    end
    @buckets  = {}   # plug_id => { bucket_ts:, sum:, count: }
    @stopping = false
  end

  def tick
    ts = @clock.call.to_i
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
        broadcast_reading(plug, ts, reading)
      rescue ShellyClient::Error, FritzDectClient::Error => e
        breaker.record_failure
        @logger.debug("plug #{plug.id} poll failed: #{e.message}")
      rescue ActiveRecord::RecordNotUnique
        # Duplicate ts (can happen on clock skew). Still broadcast last reading if we have it.
        broadcast_reading(plug, ts, reading) if reading
      rescue ActiveRecord::ConnectionNotDefined, ActiveRecord::ConnectionNotEstablished => e
        # Connection pool not ready yet on first boot — skip DB write, try next tick.
        @logger.warn("plug #{plug.id}: DB not ready (#{e.class}), skipping")
      end
    end
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

  def broadcast_reading(plug, ts, reading)
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

    ActionCable.server.broadcast("dashboard", {
      plug_id:     plug.id,
      name:        plug.name,
      role:        plug.role.to_s,
      online:      true,
      ts:          ts,
      bucket_ts:   bucket_ts,
      apower_w:    reading.apower_w,
      avg_power_w: avg_power_w,
      aenergy_wh:  reading.aenergy_wh,
    })
  rescue => e
    @logger.debug("ActionCable broadcast failed: #{e.message}")
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
