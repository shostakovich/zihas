class CreateZiwoasTables < ActiveRecord::Migration[8.1]
  def change
    create_table :samples, primary_key: [ :plug_id, :ts ] do |t|
      t.string :plug_id, null: false
      t.integer :ts, null: false
      t.float :apower_w, null: false
      t.float :aenergy_wh, null: false
    end
    add_index :samples, :ts

    create_table :samples_5min, primary_key: [ :plug_id, :bucket_ts ] do |t|
      t.string :plug_id, null: false
      t.integer :bucket_ts, null: false
      t.float :avg_power_w, null: false
      t.float :energy_delta_wh, null: false
      t.integer :sample_count, null: false
    end

    create_table :daily_totals, primary_key: [ :plug_id, :date ] do |t|
      t.string :plug_id, null: false
      t.string :date, null: false
      t.float :energy_wh, null: false
    end
  end
end
