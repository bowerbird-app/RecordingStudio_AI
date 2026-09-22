# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class DecisionResponse < Response
      attr_reader :answers

      def initialize(answers: RecordingStudioAI::Decisions::AnswerSet.empty, **common)
        @answers = answers

        super(**common, operation: "decision")
        validate_decision_fields!
      end

      def to_h
        super.merge(answers: answers.to_serializable_h)
      end

      private

      def validate_decision_fields!
        unless answers.is_a?(RecordingStudioAI::Decisions::AnswerSet)
          validation_error!("answers must be a RecordingStudioAI::Decisions::AnswerSet")
        end

        return if error.nil? || answers.empty?

        validation_error!("a failed decision response cannot carry answers")
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
