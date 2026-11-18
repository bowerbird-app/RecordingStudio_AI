# frozen_string_literal: true

require "active_job"

module RecordingStudioAI
  # Re-reads a completed hosted turn until usage arrives, then charges once.
  # The next wait is another job. +perform+ does not sleep, so a worker is
  # not held for the whole backoff.
  class HostedTurnUsageJob < ::ActiveJob::Base
    queue_as :default

    # Seconds before attempts 2, 3, 4, and 5. Attempt 1 is enqueued immediately.
    RETRY_WAITS = [5, 30, 120, 600].freeze

    def perform(run_id, attempt = 1)
      final = attempt > RETRY_WAITS.length
      finished = Agents::Runner.new.record_deferred_turn_usage(run_id, attempt: attempt, final: final)
      return if finished || final

      self.class.set(wait: RETRY_WAITS.fetch(attempt - 1)).perform_later(run_id, attempt + 1)
    end
  end
end
