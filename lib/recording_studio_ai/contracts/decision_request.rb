# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    # Fully normalized decision request. Built only by
    # RequestValidation.validate_decision_request! and never mutated afterwards.
    DecisionRequest = Data.define(:state, :questions, :profile, :purpose, :provider, :model,
                                  :fallbacks, :attribution, :metadata, :execution_deadline) do
      def initialize(state:, questions:, profile:, attribution:, **optional)
        super(**optional_defaults.merge(optional),
              state: state, questions: questions, profile: profile, attribution: attribution)
        validate!
      end

      def with_execution_deadline(value)
        with(execution_deadline: value)
      end

      # Character count only. Decision state itself never crosses the
      # persistence boundary.
      def input_character_count
        state.length
      end

      private

      def optional_defaults
        { purpose: nil, provider: nil, model: nil, fallbacks: nil, metadata: {}, execution_deadline: nil }
      end

      def validate!
        unless state.is_a?(RecordingStudioAI::Decisions::State::Text)
          validation_error!("state must be a RecordingStudioAI::Decisions::State::Text")
        end

        return if questions.is_a?(RecordingStudioAI::Decisions::QuestionSet)

        validation_error!("questions must be a RecordingStudioAI::Decisions::QuestionSet")
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
