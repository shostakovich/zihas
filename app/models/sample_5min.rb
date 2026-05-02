class Sample5min < ApplicationRecord
  self.table_name = "samples_5min"
  self.primary_key = [ :plug_id, :bucket_ts ]
end
