# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    # Planned hop: a resolved candidate plus optional hop-only generation
    # parameter overlays (from generate(fallbacks:) or config.model_fallbacks).
    # Caller overrides on the request still win over these overlays.
    PlannedCandidate = Data.define(:candidate, :profile, :parameter_overrides) do
      def initialize(candidate:, profile:, parameter_overrides: {})
        overrides = parameter_overrides.to_h.transform_keys(&:to_sym)
        known = RecordingStudioAI::Models::Definition::KNOWN_PARAMETERS
        extras = overrides.keys - known
        raise ArgumentError, "unknown planned parameter overlays: #{extras.join(', ')}" if extras.any?

        super(
          candidate: candidate,
          profile: profile,
          parameter_overrides: RecordingStudioAI::FallbackEntries.parameter_overrides_from(overrides).freeze
        )
      end
    end

    ExecutedAttempt = Data.define(:record, :result)
  end
end
