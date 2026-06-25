class CreateSceneEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :scene_entries do |t|
      t.references :scene,  null: false, foreign_key: true
      t.references :light,  null: false, foreign_key: true
      t.references :preset, null: false, foreign_key: true
      t.timestamps
    end
  end
end
