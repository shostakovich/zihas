# lib/govees/device.rb
module Govees
  Device = Struct.new(:key, :api_id, :sku, :name, :ip, :room,
                      :supports_color, :supports_color_temp,
                      :zones, :scenes, :scene_index, :power_only, keyword_init: true)
end
