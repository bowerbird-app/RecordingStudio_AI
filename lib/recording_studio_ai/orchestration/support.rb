# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    module Support
      module_function

      def identifier(value)
        value.respond_to?(:id) ? value.id : nil
      end

      def elapsed_ms(started_at, completed_at)
        ((completed_at - started_at) * 1000).round
      end

      def request_input(request)
        parts = [request[:system_instruction], request[:prompt]]
        parts.concat(Array(request[:messages]).filter_map { |message| message[:content] || message["content"] })
        parts.compact.join("\n")
      end

      def remaining_execution_time(request)
        remaining = request.fetch(:execution_deadline) - Time.current
        raise Timeout::Error if remaining <= 0

        remaining
      end
    end
  end
end
