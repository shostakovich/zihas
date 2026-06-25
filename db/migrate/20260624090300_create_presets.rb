class CreatePresets < ActiveRecord::Migration[8.1]
  def change
    create_table :presets do |t|
      t.string  :name, null: false
      t.boolean :on, null: false, default: true
      t.integer :brightness
      t.integer :color_r
      t.integer :color_g
      t.integer :color_b
      t.integer :color_temp_k
      t.timestamps
    end
  end
end
