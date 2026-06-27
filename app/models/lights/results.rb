module Lights
  module Results
    Power     = Struct.new(:light, keyword_init: true)
    Zones     = Struct.new(:light, :zone_keys, :toast, keyword_init: true)
    NoContent = Class.new
  end
end
