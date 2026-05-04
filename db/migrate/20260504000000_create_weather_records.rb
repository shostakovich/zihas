class CreateWeatherRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :weather_records do |t|
      t.string :kind, null: false
      t.datetime :timestamp, null: false
      t.float :lat, null: false
      t.float :lon, null: false
      t.integer :source_id
      t.float :precipitation
      t.float :pressure_msl
      t.float :sunshine
      t.float :temperature
      t.integer :wind_direction
      t.float :wind_speed
      t.integer :cloud_cover
      t.float :dew_point
      t.integer :relative_humidity
      t.integer :visibility
      t.integer :wind_gust_direction
      t.float :wind_gust_speed
      t.string :condition
      t.integer :precipitation_probability
      t.integer :precipitation_probability_6h
      t.float :solar
      t.string :icon
      t.string :daytime, null: false
      t.timestamps
    end

    add_index :weather_records, [ :kind, :lat, :lon, :timestamp ], unique: true, name: "idx_weather_records_identity"
    add_index :weather_records, [ :lat, :lon, :timestamp ], name: "idx_weather_records_location_ts"
  end
end
