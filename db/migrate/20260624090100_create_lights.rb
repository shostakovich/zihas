class CreateLights < ActiveRecord::Migration[8.1]
  def change
    create_table :lights do |t|
      t.string  :key,            null: false
      t.string  :name,           null: false
      t.references :room,        foreign_key: true, null: true
      t.string  :ip_address,     null: false
      t.string  :sku
      t.string  :shelly_plug_id
      t.boolean :supports_color,      null: false, default: false
      t.boolean :supports_color_temp, null: false, default: false
      t.timestamps
    end
    add_index :lights, :key, unique: true
  end
end
