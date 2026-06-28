module Lights
  module Operations
    class SetZone < Base
      def call(light:, params:, mqtt_config:)
        attrs = step validate(Contracts::Zone.new(light: light).call(zone: params[:zone], on: params[:on]))
        zone = attrs[:zone]
        on   = attrs[:on]

        evicted = on ? evict_for(light, zone) : nil
        if evicted
          step via_commander { Govees::Commander.set_zone(light, zone: evicted, on: false, mqtt_config: mqtt_config) }
          LightState.record_zone_state(light.key, evicted, false)
        end

        step via_commander { Govees::Commander.set_zone(light, zone: zone, on: on, mqtt_config: mqtt_config) }
        LightState.record_zone_state(light.key, zone, on)

        toast = evicted ? { evicted: evicted, added: zone } : nil
        Results::Zones.new(light: light, zone_keys: [ zone, evicted ].compact, toast: toast)
      end

      private

      # Which currently-on side zone must turn off so this side can come on.
      def evict_for(light, zone)
        return nil unless Light::ZONE_META.dig(zone, :role) == "side"

        max = light.max_active_zones.to_i
        return nil unless max.positive?

        bits = LightState.find_by(light_key: light.key)&.zone_states || {}
        on_zones = light.zones.select { |z| bits[z] } - [ zone ]
        return nil if on_zones.size < max

        on_zones.find { |z| Light::ZONE_META.dig(z, :role) == "side" }
      end
    end
  end
end
