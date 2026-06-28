class LightState < ApplicationRecord
  VISIBLE = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  serialize :zone_states, coder: JSON, type: Hash

  validates :light_key, presence: true, uniqueness: true

  def zone_states = super || {}

  # Writes the row and returns true when any visible field changed.
  # last_seen_at is always written but is not itself a "visible" change.
  def self.record_state(light_key, attrs)
    attrs = attrs.symbolize_keys
    state = find_or_initialize_by(light_key: light_key)
    changed = VISIBLE.any? { |f| attrs.key?(f) && state[f] != attrs[f] }
    state.assign_attributes(attrs)
    state.save!
    changed
  end

  # Upserts one zone's on/off bit atomically. Returns true when the stored value changed.
  def self.record_zone_state(light_key, instance, on)
    state = find_or_create_by(light_key: light_key)
    state.with_lock do
      current = state.zone_states
      changed = current[instance] != on
      state.update!(zone_states: current.merge(instance => on))
      return changed
    end
  end

  # Loads the states for the given light keys, indexed by key.
  def self.for_lights(keys)
    where(light_key: keys).index_by(&:light_key)
  end
end
