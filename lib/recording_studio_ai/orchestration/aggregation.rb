# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    module Aggregation
      module_function

      def usage(executions)
        usages = executions.filter_map { |execution| execution.result.usage }
        return nil if usages.empty?

        values = RecordingStudioAI::Contracts::Usage::TOKEN_FIELDS.to_h do |field|
          reported = usages.map { |usage| usage.public_send(field) }
          [field, reported.any?(&:nil?) ? nil : reported.sum]
        end
        RecordingStudioAI::Contracts::Usage.new(**values)
      end

      def cost(executions)
        costs = executions.map { |execution| execution.result.cost }
        return nil if costs.empty? || costs.any?(&:nil?)

        currencies = costs.map(&:currency).uniq
        return nil unless currencies.one?

        RecordingStudioAI::Contracts::Cost.new(
          amount: costs.sum(&:amount),
          currency: currencies.first,
          estimated: costs.any?(&:estimated?),
          source: costs.map(&:source).uniq.one? ? costs.first.source : "estimate"
        )
      end

      def token_metrics(usage)
        {
          input_tokens: usage&.input_tokens,
          output_tokens: usage&.output_tokens,
          total_tokens: usage&.total_tokens,
          cached_input_tokens: usage&.cached_input_tokens,
          reasoning_tokens: usage&.reasoning_tokens
        }
      end
    end
  end
end
