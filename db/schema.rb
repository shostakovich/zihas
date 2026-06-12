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

ActiveRecord::Schema[8.1].define(version: 2026_06_12_165251) do
  create_table "daily_energy_summary", primary_key: "date", id: :string, force: :cascade do |t|
    t.float "consumed_wh", null: false
    t.float "produced_wh", null: false
    t.float "self_consumed_wh", null: false
  end

  create_table "daily_totals", primary_key: ["plug_id", "date"], force: :cascade do |t|
    t.string "date", limit: 255, null: false
    t.float "energy_wh", null: false
    t.string "plug_id", limit: 255, null: false
  end

  create_table "plug_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "output", null: false
    t.string "plug_id", null: false
    t.datetime "updated_at", null: false
    t.index ["plug_id"], name: "index_plug_states_on_plug_id", unique: true
  end

  create_table "samples", primary_key: ["plug_id", "ts"], force: :cascade do |t|
    t.float "aenergy_wh", null: false
    t.float "apower_w", null: false
    t.string "plug_id", limit: 255, null: false
    t.integer "ts", null: false
    t.index ["ts"], name: "idx_samples_ts"
  end

  create_table "samples_5min", primary_key: ["plug_id", "bucket_ts"], force: :cascade do |t|
    t.float "avg_power_w", null: false
    t.integer "bucket_ts", null: false
    t.float "energy_delta_wh", null: false
    t.string "plug_id", limit: 255, null: false
    t.integer "sample_count", null: false
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
    t.index ["device_id", "taken_at"], name: "index_sensor_readings_on_device_id_and_taken_at"
    t.index ["taken_at"], name: "index_sensor_readings_on_taken_at"
  end

  create_table "switch_commands", force: :cascade do |t|
    t.string "action", null: false
    t.datetime "created_at", null: false
    t.string "plug_id", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.index ["plug_id", "created_at"], name: "index_switch_commands_on_plug_id_and_created_at"
  end

  create_table "switch_windows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "days", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "off_at", null: false
    t.integer "on_at", null: false
    t.string "plug_id", null: false
    t.datetime "updated_at", null: false
    t.index ["plug_id"], name: "index_switch_windows_on_plug_id"
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
    t.index ["kind", "lat", "lon", "timestamp"], name: "idx_weather_records_identity", unique: true
    t.index ["kind", "timestamp"], name: "idx_weather_records_kind_ts"
    t.index ["lat", "lon", "timestamp"], name: "idx_weather_records_location_ts"
  end
end
