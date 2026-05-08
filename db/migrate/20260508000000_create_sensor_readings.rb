class CreateSensorReadings < ActiveRecord::Migration[8.1]
  def change
    create_table :sensor_readings do |t|
      t.string   :device_id,        null: false
      t.datetime :taken_at,         null: false
      t.float    :temperature
      t.integer  :humidity
      t.integer  :co2
      t.integer  :battery_pct
      t.string   :firmware_version
      t.timestamps
    end

    add_index :sensor_readings, [ :device_id, :taken_at ]
    add_index :sensor_readings, :taken_at
  end
end
