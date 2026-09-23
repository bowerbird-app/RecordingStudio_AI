# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    # Raised when a provider is asked for an operation it does not implement.
    # Capability filtering is the router; this is the catchable shield behind it.
    class UnsupportedOperationError < StandardError
      attr_reader :operation, :provider

      def initialize(operation:, provider: nil)
        @operation = operation&.to_sym
        @provider = provider&.to_sym
        super("#{@provider || 'provider'} does not implement #{@operation || 'the requested operation'}")
      end
    end
  end
end
