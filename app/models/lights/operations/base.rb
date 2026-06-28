module Lights
  module Operations
    # Abstract base class: inherits step / Success / Failure from Dry::Operation
    # and adds coerce / validate / via_commander helpers shared by all operations.
    class Base < Dry::Operation
      private

      # Build a typed struct from raw params; coercion/structure failures => :invalid.
      def coerce
        Success(yield)
      rescue Dry::Struct::Error => e
        Failure([ :invalid, e ])
      end

      # Turn a dry-validation result into a monad of its coerced values.
      def validate(result)
        return Failure([ :invalid, result.errors ]) if result.failure?

        Success(result.to_h)
      end

      # Run a Commander side effect; broker errors => :commander.
      def via_commander
        yield
        Success()
      rescue Govees::Commander::Error => e
        Failure([ :commander, e ])
      end
    end
  end
end
