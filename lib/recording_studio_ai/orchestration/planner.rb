# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class Planner
      def initialize(configuration:, resolver: nil)
        @configuration = configuration
        @resolver = resolver || RecordingStudioAI::Resolver.new(configuration: configuration)
      end

      def plan(request, operation:)
        capability_operation = operation == :stream ? :streaming : :generation
        capabilities = RecordingStudioAI::Capabilities.for_request(request, operation: capability_operation)
        return explicit_fallbacks_plan(request, capabilities) if request[:fallbacks]

        profiles = [request[:profile]] + fallback_profiles(request[:profile])
        profiles.flat_map { |profile| candidates_for(profile, request, capabilities) }
      end

      private

      def fallback_profiles(profile)
        Array(@configuration.profile_fallbacks[profile.to_sym])
          .first(@configuration.maximum_profile_fallbacks)
          .map(&:to_sym)
      end

      def explicit_fallbacks_plan(request, capabilities)
        @resolver.candidates_from_entries(
          request[:fallbacks],
          required_capabilities: capabilities
        ).map do |candidate|
          PlannedCandidate.new(candidate: candidate, profile: request[:profile])
        end
      end

      def candidates_for(profile, request, capabilities)
        @resolver.candidates(
          profile: profile,
          provider: request[:provider],
          model: request[:model],
          required_capabilities: capabilities,
          allow_empty: profile != request[:profile]
        ).map { |candidate| PlannedCandidate.new(candidate: candidate, profile: profile.to_sym) }
      end
    end
  end
end
