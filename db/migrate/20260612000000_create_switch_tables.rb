class CreateSwitchTables < ActiveRecord::Migration[8.1]
  def change
    create_table :switch_windows do |t|
      t.string  :plug_id, null: false
      t.integer :on_at,   null: false
      t.integer :off_at,  null: false
      t.json    :days,    null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :switch_windows, :plug_id

    create_table :switch_commands do |t|
      t.string :plug_id, null: false
      t.string :action,  null: false
      t.string :source,  null: false
      t.timestamps
    end
    add_index :switch_commands, [ :plug_id, :created_at ]

    create_table :plug_states do |t|
      t.string  :plug_id, null: false
      t.boolean :output,  null: false
      t.timestamps
    end
    add_index :plug_states, :plug_id, unique: true

    create_table :scheduler_states do |t|
      t.datetime :last_tick_at, null: false
      t.timestamps
    end
  end
end
