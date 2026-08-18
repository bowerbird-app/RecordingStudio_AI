# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class CustomToolConfirmation
      def initialize(configuration:, stream_session: nil)
        @configuration = configuration
        @stream_session = stream_session
      end

      def confirm!(request, definition, arguments, invocation)
        unless definition.requires_confirmation || definition.destructive
          invocation.update!(confirmation_status: "not_required")
          return
        end

        invocation.update!(status: "awaiting_confirmation", confirmation_status: "pending")
        RecordingStudioAI::Authorization.authorize!(
          :confirm_custom_tool,
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
        apply_outcome!(request, definition, arguments, invocation)
      end

      def tool_context(request, run, requesting_attempt)
        attribution = request.fetch(:attribution)
        RecordingStudioAI::Orchestration::CustomToolContext.new(
          root_recording: attribution.root_recording,
          context_recording: attribution.context_recording,
          initiator: attribution.initiator,
          executor: attribution.executor,
          run: run,
          requesting_attempt: requesting_attempt,
          execution_source: attribution.execution_source,
          deadline: request.fetch(:execution_deadline),
          cancellation_state: RecordingStudioAI::Orchestration::CancellationState.new(
            deadline: request.fetch(:execution_deadline)
          )
        )
      end

      private

      def apply_outcome!(request, definition, arguments, invocation)
        outcome = normalize(
          @configuration.custom_tool_confirmation_handler.call(
            definition: definition,
            arguments: arguments,
            context: tool_context(request, invocation.run, invocation.requested_by_attempt)
          )
        )
        return mark_confirmed!(request, invocation) if outcome == :approved

        raise_pending!(invocation) if outcome == :pending

        reject!(invocation, outcome)
      end

      def mark_confirmed!(request, invocation)
        confirmer = request.fetch(:attribution).initiator
        invocation.update!(
          confirmation_status: "confirmed",
          confirmed_by_type: confirmer.class.name,
          confirmed_by_id: Support.identifier(confirmer),
          confirmed_at: Time.current
        )
      end

      def raise_pending!(invocation)
        invocation.update!(
          error_category: "custom_tool_confirmation_required",
          error_code: "custom_tool_confirmation_pending",
          error_message: "Custom tool confirmation is pending."
        )
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "Custom tool confirmation is pending.", code: "custom_tool_confirmation_pending"
        )
      end

      def reject!(invocation, outcome)
        confirmation_status = outcome == :expired ? "expired" : "rejected"
        error_code = outcome == :expired ? "custom_tool_confirmation_expired" : "custom_tool_confirmation_rejected"
        invocation.update!(
          status: "rejected",
          confirmation_status: confirmation_status,
          completed_at: Time.current,
          error_category: "custom_tool_rejected",
          error_code: error_code,
          error_message: "Custom tool confirmation was #{confirmation_status}."
        )
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "Custom tool confirmation was #{confirmation_status}.", code: error_code
        )
      end

      def normalize(value)
        return :approved if value == true || %w[approved confirmed].include?(value.to_s)
        return :rejected if value == false || value.nil? || value.to_s == "rejected"
        return value.to_sym if %w[pending expired].include?(value.to_s)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "custom tool confirmation handler returned an invalid outcome", code: "configuration"
        )
      end
    end
  end
end
