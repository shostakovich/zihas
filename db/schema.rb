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

ActiveRecord::Schema[8.1].define(version: 2026_05_01_000000) do
  create_table "daily_totals", primary_key: ["plug_id", "date"], force: :cascade do |t|
    t.string "date", limit: 255, null: false
    t.float "energy_wh", null: false
    t.string "plug_id", limit: 255, null: false
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
end
