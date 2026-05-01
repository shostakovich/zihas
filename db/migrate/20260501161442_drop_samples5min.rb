class DropSamples5min < ActiveRecord::Migration[8.1]
  def up
    drop_table :samples_5min
  end

  def down
    create_table :samples_5min, primary_key: [:plug_id, :bucket_ts] do |t|
      t.string  :plug_id,          null: false
      t.integer :bucket_ts,        null: false
      t.float   :avg_power_w,      null: false
      t.float   :energy_delta_wh,  null: false
      t.integer :sample_count,     null: false
    end
  end
end
