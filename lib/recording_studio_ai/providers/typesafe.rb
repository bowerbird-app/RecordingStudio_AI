# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    class TypeSafe < Base
      provider_key :typesafe

      def decide(request:, candidate:)
        questions = request.fetch(:questions)
        body = post_decision(candidate.model, request.fetch(:state), questions)
        decision_result(AnswerDecoder.call(body, questions: questions))
      rescue AnswerDecoder::InvalidResponse
        invalid_response_result
      rescue StandardError => e
        raise unless ProviderError.expected?(e)

        failed_decision_result(e)
      end

      private

      def post_decision(model, state, questions)
        client.decide(model: model, state: state.value, questions: QuestionEncoder.call(questions))
      end

      def decision_result(decoded)
        DecisionResult.new(
          answers: decoded.answers,
          usage: decoded.usage,
          metadata: { served_model: decoded.served_model }.compact,
          retention_snapshot: {
            model: decoded.served_model, status: "completed", usage: decoded.usage&.to_h
          }.compact
        )
      end

      def client
        configuration_client || RecordingStudioAI::ProviderClients::TypeSafe.new(
          api_key: configuration_api_key,
          timeout: @configuration.request_timeout
        )
      end

      def invalid_response_result
        error = RecordingStudioAI::Contracts::NormalizedError.new(
          category: "invalid_response",
          code: "invalid_decision_payload",
          message: "Provider returned an unusable decision payload.",
          retryable: false,
          provider: self.class.provider_key.to_s
        )
        DecisionResult.new(error: error, retention_snapshot: error_retention_snapshot(error))
      end
    end
  end
end
