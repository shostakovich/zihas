class DailyTotal < ApplicationRecord
  self.primary_key = [:plug_id, :date]

  validates :plug_id, presence: true
  validates :date, presence: true,
                   format: { with: /\A\d{4}-\d{2}-\d{2}\z/, message: "must be YYYY-MM-DD" }
  validates :energy_wh, presence: true, numericality: true
end
