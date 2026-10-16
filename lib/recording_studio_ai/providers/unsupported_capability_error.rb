# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    # Raised when a provider is asked for a capability it does not implement.
    class UnsupportedCapabilityError < StandardError
      attr_reader :capability, :provider

      def initialize(capability:, provider: nil)
        @capability = capability&.to_sym
        @provider = provider&.to_sym
        super("#{@provider || 'provider'} does not support #{@capability || 'the requested capability'}")
      end
    end
  end
end
