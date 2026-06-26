class AddZonesToLights < ActiveRecord::Migration[8.1]
  def change
    add_column :lights, :zones, :text
  end
end
