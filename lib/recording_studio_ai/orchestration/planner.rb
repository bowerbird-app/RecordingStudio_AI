# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class Planner
      def initialize(configuration:, resolver: nil)
        @configuration = configuration
        @resolver = resolver || RecordingStudioAI::Resolver.new(configuration: configuration)
      end

      def plan(request, operation:)
        capabilities = required_capabilities(request, operation)
        plan = if request[:fallbacks]
                 explicit_fallbacks_plan(request, capabilities)
               elsif pinned_primary?(request)
                 pinned_primary_plan(request, capabilities)
               else
                 profiles = [request[:profile]] + fallback_profiles(request[:profile])
                 profiles.flat_map { |profile| candidates_for(profile, request, capabilities) }
               end
        without_repeated_candidates(plan)
      end

      private

      # Operation dispatch is exhaustive. No unknown operation silently plans a
      # generation candidate.
      def required_capabilities(request, operation)
        case operation
        when :generation
          RecordingStudioAI::Capabilities.for_request(request, operation: :generation)
        when :stream
          RecordingStudioAI::Capabilities.for_request(request, operation: :streaming)
        when :decision
          RecordingStudioAI::Capabilities.for_decision(request)
        else
          raise RecordingStudioAI::Providers::UnsupportedOperationError.new(operation: operation)
        end
      end

      # Profile lists can name the same provider and model on more than one tier.
      # One plan runs that candidate once. Retries are a separate counter.
      def without_repeated_candidates(plan)
        seen = {}
        plan.select do |planned|
          key = [planned.candidate.provider, planned.candidate.model]
          next false if seen[key]

          seen[key] = true
        end
      end

      def pinned_primary?(request)
        !request[:provider].nil? && !request[:model].nil?
      end

      def fallback_profiles(profile)
        Array(@configuration.profile_fallbacks[profile.to_sym])
          .first(@configuration.maximum_profile_fallbacks)
          .map(&:to_sym)
      end

      def explicit_fallbacks_plan(request, capabilities)
        plan_from_entries(request[:fallbacks], request: request, capabilities: capabilities, required: true)
      end

      # Pinned provider+model: try that primary, then config.model_fallbacks for it.
      # Call-level generate(fallbacks:) already returned above. Profile walks ignore
      # model_fallbacks so low/medium/high order stays profile-owned.
      def pinned_primary_plan(request, capabilities)
        primary_plan = candidates_for(request[:profile], request, capabilities)
        return primary_plan if primary_plan.empty?

        primary = primary_plan.first.candidate
        extras = @configuration.model_fallbacks_for(primary.provider, primary.model)
        return primary_plan if extras.empty?

        seen = { [primary.provider, primary.model] => true }
        primary_plan + plan_from_entries(
          extras,
          request: request,
          capabilities: capabilities,
          seen: seen,
          required: false
        )
      end

      def candidates_for(profile, request, capabilities)
        @resolver.candidates(
          profile: profile,
          provider: request[:provider],
          model: request[:model],
          required_capabilities: capabilities,
          allow_empty: profile != request[:profile]
        ).map do |candidate|
          PlannedCandidate.new(candidate: candidate, profile: profile.to_sym)
        end
      end

      def plan_from_entries(entries, request:, capabilities:, required:, seen: {})
        planned = []
        Array(entries).each do |entry|
          key = [entry.fetch(:provider).to_sym, entry.fetch(:model).to_s]
          next if seen[key]

          seen[key] = true
          candidates = @resolver.candidates_from_entries(
            [entry.slice(:provider, :model)],
            required_capabilities: capabilities,
            allow_empty: true
          )
          next if candidates.empty?

          planned << PlannedCandidate.new(
            candidate: candidates.first,
            profile: request[:profile],
            parameter_overrides: RecordingStudioAI::FallbackEntries.parameter_overrides_from(entry)
          )
        end

        if planned.empty? && required
          @resolver.candidates_from_entries(
            Array(entries).map { |entry| entry.slice(:provider, :model) },
            required_capabilities: capabilities
          )
        end

        planned
      end
    end
  end
end
