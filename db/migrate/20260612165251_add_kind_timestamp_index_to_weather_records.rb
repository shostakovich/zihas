class AddKindTimestampIndexToWeatherRecords < ActiveRecord::Migration[8.1]
  def change
    add_index :weather_records, [ :kind, :timestamp ], name: "idx_weather_records_kind_ts"
  end
end
