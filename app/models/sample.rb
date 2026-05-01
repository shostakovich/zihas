class Sample < ApplicationRecord
  self.primary_key = [:plug_id, :ts]

  validates :plug_id, presence: true
  validates :ts, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :apower_w, presence: true, numericality: true
  validates :aenergy_wh, presence: true, numericality: true
end
