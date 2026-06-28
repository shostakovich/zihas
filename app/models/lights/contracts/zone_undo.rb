module Lights
  module Contracts
    class ZoneUndo < Dry::Validation::Contract
      option :light

      params do
        required(:victim).filled(:string)
        required(:added).filled(:string)
      end

      rule(:victim) do
        key.failure("is not a zone of this light") unless light.zones.include?(value)
      end

      rule(:added) do
        key.failure("is not a zone of this light") unless light.zones.include?(value)
      end
    end
  end
end
