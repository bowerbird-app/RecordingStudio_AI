# frozen_string_literal: true

module RecordingStudioAI
  module Agents
    module Resolution
      module_function

      def call(profile:, model:, provider:)
        return resolve_model(model, provider) if model && profile.nil?

        RecordingStudioAI::Resolver.new.resolve(
          profile: profile || RecordingStudioAI.configuration.default_profile,
          required_capabilities: [:hosted_agent],
          provider: provider,
          model: model
        )
      end

      def resolve_model(model, provider)
        entries = registry_entries(model, provider)
        missing!(model) if entries.empty?
        ensure_override!(provider)
        configured = entries.select { |entry| configured?(entry[:provider]) }
        unavailable!(model) if configured.empty?
        RecordingStudioAI::Resolver.new.candidates_from_entries(
          configured, required_capabilities: [:hosted_agent]
        ).first
      end

      def registry_entries(model, provider)
        RecordingStudioAI.models.all.filter_map do |definition|
          next unless definition.model == model.to_s
          next if provider && definition.provider != provider.to_sym

          { provider: definition.provider, model: definition.model }
        end
      end

      def configured?(provider)
        adapter = RecordingStudioAI.configuration.providers[provider]
        adapter && (!adapter.respond_to?(:configured?) || adapter.configured?)
      end

      def ensure_override!(provider)
        return if provider.nil?

        allowed = Array(RecordingStudioAI.configuration.allowed_provider_overrides).map(&:to_sym)
        return if allowed.include?(provider.to_sym)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "Provider override #{provider} is not enabled",
          code: "configuration"
        )
      end

      def missing!(model)
        raise RecordingStudioAI::Errors::ResolutionError.new(
          category: "configuration",
          code: "missing_model",
          message: "No model named #{model} is configured."
        )
      end

      def unavailable!(model)
        raise RecordingStudioAI::Errors::ResolutionError.new(
          category: "configuration",
          code: "not_configured",
          message: "No configured provider can serve model #{model}."
        )
      end
    end
  end
end
