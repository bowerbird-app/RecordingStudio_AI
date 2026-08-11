# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class GenerationResponse < Response
      attr_reader :text, :structured_data, :citations, :provider_native_tools, :custom_tool_invocations, :finish_reason

      def initialize(
        text: nil,
        structured_data: nil,
        citations: [],
        provider_native_tools: [],
        custom_tool_invocations: [],
        finish_reason: nil,
        **
      )
        @text = text
        @structured_data = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          structured_data,
          path: "structured_data"
        )
        @citations = citations
        @provider_native_tools = provider_native_tools
        @custom_tool_invocations = custom_tool_invocations
        @finish_reason = finish_reason

        super(**)
        validate_generation_fields!
      end

      def to_h
        super.merge(
          text: text,
          structured_data: structured_data,
          citations: citations.map(&:to_h),
          provider_native_tools: provider_native_tools,
          custom_tool_invocations: custom_tool_invocations,
          finish_reason: finish_reason
        )
      end

      private

      def validate_generation_fields!
        unless text.nil? || text.is_a?(String)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "text must be a String or nil",
            code: "invalid_request"
          )
        end

        unless citations.all? { |item| item.is_a?(RecordingStudioAI::Contracts::Citation) }
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "citations must contain only RecordingStudioAI::Contracts::Citation items",
            code: "invalid_request"
          )
        end

        RecordingStudioAI::Contracts::Containment.ensure_serializable!(provider_native_tools,
                                                                       path: "provider_native_tools")
        RecordingStudioAI::Contracts::Containment.ensure_serializable!(custom_tool_invocations,
                                                                       path: "custom_tool_invocations")
      end
    end
  end
end
