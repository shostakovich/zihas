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
    @stopping = false
  end

  def tick
    ts = @clock.call.to_i
    @plugs.each do |plug|
      breaker = @breakers[plug.id]
      next if breaker.skip?

      begin
        reading = @clients[plug.id].fetch(plug)
        Sample.create(
          plug_id:    plug.id,
          ts:         ts,
          apower_w:   reading.apower_w,
          aenergy_wh: reading.aenergy_wh,
        )
        breaker.record_success
      rescue ShellyClient::Error, FritzDectClient::Error => e
        breaker.record_failure
        @logger.debug("plug #{plug.id} poll failed: #{e.message}")
      rescue ActiveRecord::RecordNotUnique
        # Duplicate ts (can happen on clock skew). Swallow to keep the loop alive.
      end
    end
  end

  def run(interval)
    until @stopping
      start = @clock.call
      tick
      elapsed = @clock.call - start
      sleep_for = interval - elapsed
      sleep(sleep_for) if sleep_for.positive? && !@stopping
    end
  end

  def stop!
    @stopping = true
  end

  private

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
