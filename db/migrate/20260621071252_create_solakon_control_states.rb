class CreateSolakonControlStates < ActiveRecord::Migration[8.1]
  def change
    create_table :solakon_control_states do |t|
      t.boolean :auto_regulation_paused, null: false, default: false

      t.timestamps
    end
  end
end
