# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    PlannedCandidate = Data.define(:candidate, :profile)
    ExecutedAttempt = Data.define(:record, :result)
  end
end
