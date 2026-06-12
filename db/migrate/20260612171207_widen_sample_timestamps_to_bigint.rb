class WidenSampleTimestampsToBigint < ActiveRecord::Migration[8.1]
  def up
    change_column :samples, :ts, :bigint, null: false
    change_column :samples_5min, :bucket_ts, :bigint, null: false
  end

  def down
    change_column :samples, :ts, :integer, null: false
    change_column :samples_5min, :bucket_ts, :integer, null: false
  end
end
