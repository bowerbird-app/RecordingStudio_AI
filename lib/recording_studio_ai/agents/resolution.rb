# frozen_string_literal: true

module RecordingStudioAI
  module Agents
    Resolved = Data.define(:candidate, :reasoning_effort)

    module Resolution
      module_function

      def call(profile:, model:, provider:)
        if model && profile.nil?
          candidate = resolve_model(model, provider)
          return resolved(candidate, nil)
        end

        entry, candidate = RecordingStudioAI::Resolver.new.entry_pairs(
          profile: profile || RecordingStudioAI.configuration.default_profile,
          required_capabilities: [:hosted_agent],
          provider: provider,
          model: model
        ).first
        resolved(candidate, entry)
      end

      # Profile entry wins. Otherwise the model spec default is sent.
      # Astra has no default, so an unset entry sends nothing.
      def resolved(candidate, entry)
        Resolved.new(candidate: candidate, reasoning_effort: reasoning_effort_for(candidate, entry))
      end

      def reasoning_effort_for(candidate, entry)
        if entry.is_a?(Hash)
          effort = entry.transform_keys(&:to_sym)[:reasoning_effort]
          return effort.to_s unless effort.nil?
        end

        definition = RecordingStudioAI.models.fetch(candidate.provider, candidate.model)
        default_effort(definition)
      end

      def default_effort(definition)
        parameter = definition&.parameter(:reasoning_effort)
        return if parameter.nil?

        parameter[:default]&.to_s
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
