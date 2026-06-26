class AddFirmwareScenesToLights < ActiveRecord::Migration[8.1]
  def change
    add_column :lights, :firmware_scenes, :text
  end
end
