module Lights
  module Params
    class Turn < Dry::Struct
      attribute :on, Types::Bool
    end

    class Brightness < Dry::Struct
      attribute :value, Types::Brightness
    end

    class Color < Dry::Struct
      attribute :r, Types::RgbComponent
      attribute :g, Types::RgbComponent
      attribute :b, Types::RgbComponent
    end

    class ColorTemp < Dry::Struct
      attribute :kelvin, Types::Kelvin
    end

    class Scene < Dry::Struct
      attribute :scene, Types::SceneName
    end
  end
end
