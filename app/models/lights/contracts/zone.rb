module Lights
  module Contracts
    class Zone < Dry::Validation::Contract
      option :light

      params do
        required(:zone).filled(:string)
        required(:on).filled(:bool)
      end

      rule(:zone) do
        key.failure("is not a zone of this light") unless light.zones.include?(value)
      end
    end
  end
end
