class AddZoneStatesToLightStates < ActiveRecord::Migration[8.1]
  def change
    add_column :light_states, :zone_states, :text
  end
end
