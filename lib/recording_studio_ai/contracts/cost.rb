# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class Cost
      SOURCES = %w[provider catalog estimate unavailable].freeze

      attr_reader :amount, :currency, :source

      def initialize(amount: nil, currency: nil, estimated: nil, source: nil)
        @amount = amount
        @currency = currency
        @estimated = estimated.nil? ? nil : !!estimated
        @source = source&.to_s

        validate!
      end

      def estimated?
        @estimated
      end

      def to_h
        {
          amount: amount,
          currency: currency,
          estimated: estimated?,
          source: source
        }
      end

      private

      def validate!
        unless amount.nil? || (amount.is_a?(Integer) && amount >= 0)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "amount must be a nonnegative Integer in microunits",
            code: "invalid_request"
          )
        end

        unless currency.nil? || currency.is_a?(String)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "currency must be a String",
            code: "invalid_request"
          )
        end

        return if source.nil? || SOURCES.include?(source)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "source must be one of: #{SOURCES.join(', ')}",
          code: "invalid_request"
        )
      end
    end
  end
end
