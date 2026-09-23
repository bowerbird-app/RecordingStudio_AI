# frozen_string_literal: true

require "json"

module RecordingStudioAI
  module Providers
    # Decision payloads are typed answers. They deliberately never travel as
    # text, structured_data, citations, or tool calls.
    class DecisionResult < ExecutionResult
      attr_reader :answers

      def initialize(answers: RecordingStudioAI::Decisions::AnswerSet.empty, **common)
        validate_answers!(answers, common[:error])
        @answers = answers

        super(**common)
      end

      def with(**overrides)
        self.class.new(**execution_attributes, answers: answers, **overrides)
      end

      def output_character_count
        JSON.generate(answers.to_serializable_h).length
      end

      private

      def validate_answers!(answer_set, error)
        unless answer_set.is_a?(RecordingStudioAI::Decisions::AnswerSet)
          validation_error!("answers must be a RecordingStudioAI::Decisions::AnswerSet")
        end
        return if error.nil? || answer_set.empty?

        validation_error!("a failed decision result cannot carry answers")
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
