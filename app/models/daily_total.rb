class DailyTotal < ApplicationRecord
  self.primary_key = [:plug_id, :date]
end
