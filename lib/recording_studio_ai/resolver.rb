# frozen_string_literal: true

module RecordingStudioAI
  class Resolver
    Result = Data.define(:candidate, :error) do
      def success?
        !candidate.nil?
      end
    end

    def initialize(configuration: RecordingStudioAI.configuration)
      @configuration = configuration
    end

    def resolve(profile:, required_capabilities:, provider: nil)
      candidates(
        profile: profile,
        required_capabilities: required_capabilities,
        provider: provider
      ).first
    end

    def candidates(profile:, required_capabilities:, provider: nil, allow_empty: false)
      provider_key = validate_override!(provider)
      candidates = Array(@configuration.profiles[profile.to_sym]).map { |entry| build_candidate(entry) }
      candidates.select! { |candidate| candidate.provider == provider_key } if provider_key
      candidates.select! do |candidate|
        adapter = @configuration.adapters[candidate.provider]
        adapter && (!adapter.respond_to?(:configured?) || adapter.configured?)
      end

      eligible = candidates.select { |candidate| candidate.supports?(required_capabilities) }
      return eligible if eligible.any? || allow_empty

      raise_resolution_error!(candidates, required_capabilities)
    end

    private

    def validate_override!(provider)
      return nil if provider.nil?

      provider_key = provider.to_sym
      return provider_key if Array(@configuration.allowed_provider_overrides).map(&:to_sym).include?(provider_key)

      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "Provider override #{provider_key} is not enabled",
        code: "configuration"
      )
    end

    def build_candidate(entry)
      return entry if entry.is_a?(RecordingStudioAI::Candidate)

      RecordingStudioAI::Candidate.new(**entry.transform_keys(&:to_sym))
    end

    def raise_resolution_error!(candidates, required_capabilities)
      category = candidates.empty? ? "configuration" : "unsupported_capability"
      code = candidates.empty? ? "not_implemented" : "unsupported_capability"
      message = if candidates.empty?
                  "No candidates are configured for the requested profile and provider."
                else
                  "No candidate supports all required capabilities: #{required_capabilities.join(', ')}"
                end

      raise RecordingStudioAI::Errors::ResolutionError.new(category: category, code: code, message: message)
    end
  end
end
