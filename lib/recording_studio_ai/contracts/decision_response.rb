# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class DecisionResponse < Response
      attr_reader :answers, :served_model

      def initialize(answers: RecordingStudioAI::Decisions::AnswerSet.empty, served_model: nil, **common)
        @answers = answers
        @served_model = served_model

        super(**common, operation: "decision")
        validate_decision_fields!
      end

      def to_h
        super.merge(answers: answers.to_serializable_h, served_model: served_model)
      end

      private

      def validate_decision_fields!
        validate_answers!
        validate_served_model!
        return if error.nil? || answers.empty?

        validation_error!("a failed decision response cannot carry answers")
      end

      def validate_answers!
        return if answers.is_a?(RecordingStudioAI::Decisions::AnswerSet)

        validation_error!("answers must be a RecordingStudioAI::Decisions::AnswerSet")
      end

      def validate_served_model!
        return if served_model.nil? || (served_model.is_a?(String) && !served_model.strip.empty?)

        validation_error!("served_model must be a non-empty String")
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
