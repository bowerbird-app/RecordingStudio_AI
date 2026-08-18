# frozen_string_literal: true

require "json"
require "timeout"

module RecordingStudioAI
  module Orchestration
    class CustomToolExecution
      def initialize(configuration:, records:, stream_session: nil)
        @configuration = configuration
        @records = records
        @stream_session = stream_session
        @confirmation = CustomToolConfirmation.new(configuration: configuration, stream_session: stream_session)
      end

      def execute(run, request, requesting_attempt, tool_call)
        definition = request.fetch(:custom_tool_definitions).find { |item| item.key == tool_call.key }
        return @records.unknown(run, requesting_attempt, tool_call) unless definition

        invocation = @records.create!(run, requesting_attempt, tool_call, definition)
        emit("custom_tool_requested", invocation)
        run_authorized_tool(request, definition, invocation, tool_call)
      rescue RecordingStudioAI::Errors::ContractValidationError => e
        handle_contract_error(e, invocation)
      rescue Timeout::Error
        @records.fail!(invocation, "failed", "custom_tool_failed", "custom_tool_timeout",
                       "Custom tool execution timed out.")
        { error: failure("custom_tool_timeout") }
      rescue StandardError
        @records.fail!(invocation, "failed", "custom_tool_failed", "custom_tool_execution",
                       "Custom tool execution failed.")
        { error: failure("custom_tool_execution") }
      ensure
        @stream_session&.active_cancellation_state = nil
      end

      def tool_timeout(request)
        [Support.remaining_execution_time(request), @configuration.custom_tool_timeout].min
      end

      private

      def run_authorized_tool(request, definition, invocation, tool_call)
        arguments = definition.validate_arguments!(tool_call.arguments)
        authorize!(request, definition, invocation)
        @confirmation.confirm!(request, definition, arguments, invocation)
        invocation.update!(status: "authorized")
        invocation.update!(status: "running", started_at: Time.current)
        emit("custom_tool_started", invocation)
        context = @confirmation.tool_context(request, invocation.run, invocation.requested_by_attempt)
        @stream_session&.active_cancellation_state = context.cancellation_state
        raise_cancelled! if context.cancellation_state.cancelled?
        result = Timeout.timeout(tool_timeout(request)) { definition.executor.call(arguments, context) }
        raise_cancelled! if context.cancellation_state.cancelled?
        serializable_result = ensure_result_size!(result)
        success_outcome(invocation, tool_call, definition, serializable_result)
      end

      def ensure_result_size!(result)
        serializable_result = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          result, path: "custom_tool.result"
        )
        serialized_result = JSON.generate(serializable_result)
        if serialized_result.bytesize > @configuration.maximum_custom_tool_result_size
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "custom tool result exceeds the configured byte limit",
            code: "custom_tool_result_too_large"
          )
        end

        serializable_result
      end

      def success_outcome(invocation, tool_call, definition, serializable_result)
        {
          invocation: invocation,
          result: serializable_result,
          provider_result: {
            provider_tool_call_id: tool_call.provider_tool_call_id,
            tool_key: definition.key,
            result: serializable_result
          },
          error: nil
        }
      end

      def handle_contract_error(error, invocation)
        status, category = contract_error_status(error.code)
        @records.fail!(invocation, status, category, error.code, error.message) if invocation && status
        { error: failure(error.code, category: category, message: error.message) }
      end

      def contract_error_status(code)
        case code
        when "authorization" then %w[denied custom_tool_denied]
        when "custom_tool_confirmation_rejected", "custom_tool_confirmation_expired"
          %w[rejected custom_tool_rejected]
        when "custom_tool_confirmation_pending" then [nil, "custom_tool_confirmation_required"]
        when "custom_tool_cancelled" then %w[cancelled cancelled]
        when "custom_tool_validation" then %w[failed custom_tool_validation]
        else %w[failed custom_tool_failed]
        end
      end

      def authorize!(request, definition, invocation)
        RecordingStudioAI::Authorization.authorize!(
          :use_custom_tool,
          attribution: request.fetch(:attribution),
          context: {
            tool_key: definition.key,
            tool_version: definition.version,
            invocation_id: invocation.id,
            read_only: definition.read_only,
            destructive: definition.destructive,
            requires_confirmation: definition.requires_confirmation
          }
        )
      end

      def raise_cancelled!
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "Custom tool execution was cancelled.", code: "custom_tool_cancelled"
        )
      end

      def failure(code, category: "custom_tool_failed", message: "Custom tool execution failed.")
        RecordingStudioAI::Providers::Result.new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: category, code: code, message: message, retryable: false
          )
        )
      end

      def emit(type, invocation)
        @stream_session&.emit(type, metadata: {
                                invocation_id: invocation.id,
                                provider_tool_call_id: invocation.provider_tool_call_id,
                                tool_key: invocation.tool_key,
                                tool_version: invocation.tool_version,
                                status: invocation.status
                              })
      end
    end
  end
end
