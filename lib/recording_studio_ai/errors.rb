# frozen_string_literal: true

module RecordingStudioAI
  module Errors
    class ResolutionError < StandardError
      attr_reader :category, :code

      def initialize(category:, code:, message:)
        @category = category
        @code = code
        super(message)
      end
    end

    class ContractValidationError < ArgumentError
      attr_reader :code, :details

      def initialize(message, code: "invalid_request", details: {})
        @code = code
        @details = details
        super(message)
      end
    end

    class ExecutionError < StandardError
      attr_reader :response

      def initialize(response)
        @response = response
        error_message = response.error&.message || "Execution failed"
        super(error_message)
      end
    end
  end
end
