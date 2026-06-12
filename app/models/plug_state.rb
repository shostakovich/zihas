class PlugState < ApplicationRecord
  validates :plug_id, presence: true, uniqueness: true
  validates :output, inclusion: { in: [ true, false ] }

  # Returns true when the stored output actually changed (and was written).
  def self.record_output(plug_id, output)
    state = find_or_initialize_by(plug_id: plug_id)
    return false if state.persisted? && state.output == output
    state.update!(output: output)
    true
  end
end
