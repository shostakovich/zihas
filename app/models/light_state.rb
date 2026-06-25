class LightState < ApplicationRecord
  VISIBLE = %i[on brightness color_r color_g color_b color_temp_k reachable].freeze

  validates :light_key, presence: true, uniqueness: true

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
end
