class DailyEnergySummary < ApplicationRecord
  self.table_name = "daily_energy_summary"
  self.primary_key = :date

  validates :date, presence: true,
                   format: { with: /\A\d{4}-\d{2}-\d{2}\z/, message: "must be YYYY-MM-DD" }
  validates :produced_wh, :consumed_wh, :self_consumed_wh,
            presence: true, numericality: true
end
