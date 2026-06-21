class ExtendSolakonReadingsForLiveDetails < ActiveRecord::Migration[8.1]
  def change
    change_table :solakon_readings do |t|
      t.float :battery_voltage_v
      t.float :battery_current_a
      t.float :inverter_temperature_c
      t.integer :status1
      t.integer :status3
      t.integer :alarm1
      t.integer :alarm2
      t.integer :alarm3
      t.boolean :eps_enabled
      t.float :eps_voltage_v
      t.float :eps_power_w
    end
  end
end
