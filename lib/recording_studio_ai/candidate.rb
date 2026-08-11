# frozen_string_literal: true

module RecordingStudioAI
  class Candidate
    attr_reader :provider, :model, :capabilities

    def initialize(provider:, model:, capabilities:)
      @provider = provider.to_sym
      @model = model.to_s
      @capabilities = Array(capabilities).map(&:to_sym).uniq.freeze

      unknown = @capabilities - RecordingStudioAI::Capabilities::ALL
      raise ArgumentError, "Unknown capabilities: #{unknown.join(', ')}" if unknown.any?
      raise ArgumentError, "provider is required" if @provider.to_s.empty?
      raise ArgumentError, "model is required" if @model.empty?

      freeze
    end

    def supports?(required_capabilities)
      (Array(required_capabilities).map(&:to_sym) - capabilities).empty?
    end
  end
end
