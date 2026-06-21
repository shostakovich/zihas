class CreateSolakonSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :solakon_snapshots do |t|
      t.datetime :taken_at, null: false
      t.float :pv1_power_w
      t.float :pv1_voltage_v
      t.float :pv1_current_a
      t.float :pv2_power_w
      t.float :pv2_voltage_v
      t.float :pv2_current_a
      t.float :pv3_power_w
      t.float :pv3_voltage_v
      t.float :pv3_current_a
      t.float :pv4_power_w
      t.float :pv4_voltage_v
      t.float :pv4_current_a
      t.float :battery_voltage_v
      t.float :battery_current_a
      t.float :battery_power_w
      t.integer :battery_soc_pct
      t.float :battery_temperature_c
      t.float :battery_min_temperature_c
      t.integer :battery_health_pct
      t.float :remaining_energy_wh
      t.float :full_charge_capacity_ah
      t.float :design_energy_wh
      t.float :inverter_temperature_c
      t.float :grid_power_w
      t.boolean :eps_enabled
      t.float :eps_voltage_v
      t.float :eps_power_w
      t.integer :status1
      t.integer :status3
      t.integer :alarm1
      t.integer :alarm2
      t.integer :alarm3
      t.json :bms_faults, null: false, default: []
      t.float :pv_total_kwh
      t.float :battery_charge_total_kwh
      t.float :battery_discharge_total_kwh
      t.float :grid_export_total_kwh
      t.float :grid_import_total_kwh

      t.timestamps
    end

    add_index :solakon_snapshots, :taken_at
  end
end
