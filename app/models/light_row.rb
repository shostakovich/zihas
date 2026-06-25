# Per-light view model for the "Schalten" tab.
class LightRow
  attr_reader :light, :state

  def self.build_all(lights)
    lights  = lights.to_a
    states  = LightState.where(light_key: lights.map(&:key)).index_by(&:light_key)
    lights.map { |l| new(light: l, state: states[l.key]) }
  end

  def initialize(light:, state:)
    @light = light
    @state = state
  end

  def on?         = !!state&.on
  def brightness  = state&.brightness || 0
  def reachable?  = !!state&.reachable
end
