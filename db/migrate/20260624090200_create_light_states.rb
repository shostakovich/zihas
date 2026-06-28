class CreateLightStates < ActiveRecord::Migration[8.1]
  def change
    create_table :light_states do |t|
      t.string   :light_key, null: false
      t.boolean  :on
      t.integer  :brightness
      t.integer  :color_r
      t.integer  :color_g
      t.integer  :color_b
      t.integer  :color_temp_k
      t.boolean  :reachable
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :light_states, :light_key, unique: true
  end
end
