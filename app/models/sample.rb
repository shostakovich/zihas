class Sample < ApplicationRecord
  self.primary_key = [:plug_id, :ts]
end
