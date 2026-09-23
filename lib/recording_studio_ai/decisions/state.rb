# frozen_string_literal: true

module RecordingStudioAI
  module Decisions
    module State
      module_function

      # V1 accepts text state only. Hash and Array state are reserved for a
      # later revision and are rejected rather than coerced.
      def parse(value)
        Decisions.validation_error!("state must be a String") unless value.is_a?(String)

        Text.new(value: value)
      end

      class Text
        attr_reader :value

        def initialize(value:)
          unless value.is_a?(String) && !value.strip.empty?
            Decisions.validation_error!("state must be a non-empty String")
          end
          limit = Decisions.maximum_state_characters
          Decisions.validation_error!("state must be at most #{limit} characters") if value.length > limit

          @value = value.dup.freeze
          freeze
        end

        def length
          value.length
        end

        def to_s
          value
        end
      end
    end
  end
end
