class CreateDailyEnergySummary < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_energy_summary, primary_key: [ :date ] do |t|
      t.string :date, null: false
      t.float  :produced_wh, null: false
      t.float  :consumed_wh, null: false
      t.float  :self_consumed_wh, null: false
    end
  end
end
