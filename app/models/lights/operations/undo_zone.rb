module Lights
  module Operations
    class UndoZone < Base
      def call(light:, params:, mqtt_config:)
        attrs = step validate(Contracts::ZoneUndo.new(light: light).call(victim: params[:victim], added: params[:added]))
        victim = attrs[:victim]
        added  = attrs[:added]

        step via_commander { Govees::Commander.set_zone(light, zone: victim, on: true, mqtt_config: mqtt_config) }
        LightState.record_zone_state(light.key, victim, true)

        step via_commander { Govees::Commander.set_zone(light, zone: added, on: false, mqtt_config: mqtt_config) }
        LightState.record_zone_state(light.key, added, false)

        Results::Zones.new(light: light, zone_keys: [ victim, added ], toast: :clear)
      end
    end
  end
end
