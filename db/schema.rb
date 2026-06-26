# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_26_153412) do
  create_table "daily_energy_summary", primary_key: "date", id: :string, force: :cascade do |t|
    t.float "consumed_wh", null: false
    t.float "produced_wh", null: false
    t.float "self_consumed_wh", null: false
  end

  create_table "daily_totals", primary_key: [ "plug_id", "date" ], force: :cascade do |t|
    t.string "date", limit: 255, null: false
    t.float "energy_wh", null: false
    t.string "plug_id", limit: 255, null: false
  end

  create_table "light_states", force: :cascade do |t|
    t.integer "brightness"
    t.integer "color_b"
    t.integer "color_g"
    t.integer "color_r"
    t.integer "color_temp_k"
    t.datetime "created_at", null: false
    t.datetime "last_seen_at"
    t.string "light_key", null: false
    t.boolean "on"
    t.boolean "reachable"
    t.datetime "updated_at", null: false
    t.index [ "light_key" ], name: "index_light_states_on_light_key", unique: true
  end

  create_table "lights", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "firmware_scenes"
    t.string "key", null: false
    t.string "name", null: false
    t.integer "room_id"
    t.string "shelly_plug_id"
    t.string "sku"
    t.boolean "supports_color", default: false, null: false
    t.boolean "supports_color_temp", default: false, null: false
    t.datetime "updated_at", null: false
    t.index [ "key" ], name: "index_lights_on_key", unique: true
    t.index [ "room_id" ], name: "index_lights_on_room_id"
  end

  create_table "plug_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "output", null: false
    t.string "plug_id", null: false
    t.datetime "updated_at", null: false
    t.index [ "plug_id" ], name: "index_plug_states_on_plug_id", unique: true
  end

  create_table "presets", force: :cascade do |t|
    t.integer "brightness"
    t.integer "color_b"
    t.integer "color_g"
    t.integer "color_r"
    t.integer "color_temp_k"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.boolean "on", default: true, null: false
    t.datetime "updated_at", null: false
  end

  create_table "rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index [ "name" ], name: "index_rooms_on_name", unique: true
  end

  create_table "samples", primary_key: [ "plug_id", "ts" ], force: :cascade do |t|
    t.float "aenergy_wh", null: false
    t.float "apower_w", null: false
    t.string "plug_id", limit: 255, null: false
    t.bigint "ts", null: false
    t.index [ "ts" ], name: "idx_samples_ts"
  end

  create_table "samples_5min", primary_key: [ "plug_id", "bucket_ts" ], force: :cascade do |t|
    t.float "avg_power_w", null: false
    t.bigint "bucket_ts", null: false
    t.float "energy_delta_wh", null: false
    t.string "plug_id", limit: 255, null: false
    t.integer "sample_count", null: false
  end

  create_table "scene_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "light_id", null: false
    t.integer "preset_id", null: false
    t.integer "scene_id", null: false
    t.datetime "updated_at", null: false
    t.index [ "light_id" ], name: "index_scene_entries_on_light_id"
    t.index [ "preset_id" ], name: "index_scene_entries_on_preset_id"
    t.index [ "scene_id" ], name: "index_scene_entries_on_scene_id"
  end

  create_table "scenes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "scheduler_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_tick_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sensor_readings", force: :cascade do |t|
    t.integer "battery_pct"
    t.integer "co2"
    t.datetime "created_at", null: false
    t.string "device_id", null: false
    t.string "firmware_version"
    t.integer "humidity"
    t.datetime "taken_at", null: false
    t.float "temperature"
    t.datetime "updated_at", null: false
    t.index [ "device_id", "taken_at" ], name: "index_sensor_readings_on_device_id_and_taken_at"
    t.index [ "taken_at" ], name: "index_sensor_readings_on_taken_at"
  end

  create_table "solakon_control_states", force: :cascade do |t|
    t.boolean "auto_regulation_paused", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "solakon_readings", force: :cascade do |t|
    t.float "active_power_w", null: false
    t.integer "alarm1"
    t.integer "alarm2"
    t.integer "alarm3"
    t.float "battery_current_a"
    t.float "battery_power_w", null: false
    t.integer "battery_soc_pct", null: false
    t.float "battery_temperature_c"
    t.float "battery_voltage_v"
    t.datetime "created_at", null: false
    t.boolean "eps_enabled"
    t.float "eps_power_w"
    t.float "eps_voltage_v"
    t.float "inverter_temperature_c"
    t.float "pv_power_w", null: false
    t.integer "status1"
    t.integer "status3"
    t.datetime "taken_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "taken_at" ], name: "index_solakon_readings_on_taken_at"
  end

  create_table "solakon_snapshots", force: :cascade do |t|
    t.float "active_power_w"
    t.integer "alarm1"
    t.integer "alarm2"
    t.integer "alarm3"
    t.float "battery_charge_total_kwh"
    t.float "battery_current_a"
    t.float "battery_discharge_total_kwh"
    t.integer "battery_health_pct"
    t.float "battery_min_temperature_c"
    t.float "battery_power_w"
    t.integer "battery_soc_pct"
    t.float "battery_temperature_c"
    t.float "battery_voltage_v"
    t.json "bms_faults", default: [], null: false
    t.datetime "created_at", null: false
    t.float "design_energy_wh"
    t.boolean "eps_enabled"
    t.float "eps_power_w"
    t.float "eps_voltage_v"
    t.float "full_charge_capacity_ah"
    t.float "grid_export_total_kwh"
    t.float "grid_import_total_kwh"
    t.float "grid_power_w"
    t.float "inverter_temperature_c"
    t.float "pv1_current_a"
    t.float "pv1_power_w"
    t.float "pv1_voltage_v"
    t.float "pv2_current_a"
    t.float "pv2_power_w"
    t.float "pv2_voltage_v"
    t.float "pv3_current_a"
    t.float "pv3_power_w"
    t.float "pv3_voltage_v"
    t.float "pv4_current_a"
    t.float "pv4_power_w"
    t.float "pv4_voltage_v"
    t.float "pv_total_kwh"
    t.float "remaining_energy_wh"
    t.integer "status1"
    t.integer "status3"
    t.datetime "taken_at", null: false
    t.datetime "updated_at", null: false
    t.index [ "taken_at" ], name: "index_solakon_snapshots_on_taken_at"
  end

  create_table "switch_commands", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.string "plug_id", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index [ "plug_id", "created_at" ], name: "index_switch_commands_on_plug_id_and_created_at"
  end

  create_table "switch_windows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "days", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "off_at", null: false
    t.integer "on_at", null: false
    t.string "plug_id", null: false
    t.datetime "updated_at", null: false
    t.index [ "plug_id" ], name: "index_switch_windows_on_plug_id"
  end

  create_table "weather_records", force: :cascade do |t|
    t.integer "cloud_cover"
    t.string "condition"
    t.datetime "created_at", null: false
    t.string "daytime", null: false
    t.float "dew_point"
    t.string "icon"
    t.string "kind", null: false
    t.float "lat", null: false
    t.float "lon", null: false
    t.float "precipitation"
    t.integer "precipitation_probability"
    t.integer "precipitation_probability_6h"
    t.float "pressure_msl"
    t.integer "relative_humidity"
    t.float "solar"
    t.integer "source_id"
    t.float "sunshine"
    t.float "temperature"
    t.datetime "timestamp", null: false
    t.datetime "updated_at", null: false
    t.integer "visibility"
    t.integer "wind_direction"
    t.integer "wind_gust_direction"
    t.float "wind_gust_speed"
    t.float "wind_speed"
    t.index [ "kind", "lat", "lon", "timestamp" ], name: "idx_weather_records_identity", unique: true
    t.index [ "kind", "timestamp" ], name: "idx_weather_records_kind_ts"
    t.index [ "lat", "lon", "timestamp" ], name: "idx_weather_records_location_ts"
  end

  add_foreign_key "lights", "rooms"
  add_foreign_key "scene_entries", "lights"
  add_foreign_key "scene_entries", "presets"
  add_foreign_key "scene_entries", "scenes"
end
