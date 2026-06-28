module Lights
  module Operations
    class SetScene < Base
      def call(light:, params:, mqtt_config:)
        attrs = step coerce { Params::Scene.new(scene: params[:effect] || params[:scene]) }
        step via_commander { Govees::Commander.set_scene(light, scene: attrs.scene, mqtt_config: mqtt_config) }
        Results::NoContent.new
      end
    end
  end
end
