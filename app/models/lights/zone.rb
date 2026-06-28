module Lights
  class Zone < Dry::Struct
    attribute :key,   Types::String
    attribute :label, Types::String
    attribute :role,  Types::String
    attribute :on,    Types::Bool
  end
end
