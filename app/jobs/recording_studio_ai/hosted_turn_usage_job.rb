# frozen_string_literal: true

require "active_job"

module RecordingStudioAI
  # Re-reads a completed hosted turn until usage arrives, then charges once.
  # Waits sit between attempts. The request that enqueued the job does not sleep.
  class HostedTurnUsageJob < ::ActiveJob::Base
    queue_as :default

    # Seconds before attempts 2, 3, 4, and 5. Attempt 1 runs immediately.
    RETRY_WAITS = [5, 30, 120, 600].freeze

    def perform(run_id)
      runner = Agents::Runner.new
      finished = false
      RETRY_WAITS.each_with_index do |wait, index|
        finished = runner.record_deferred_turn_usage(run_id, attempt: index + 1, final: false)
        break if finished

        RecordingStudioAI.configuration.retry_sleeper.call(wait)
      end
      return if finished

      runner.record_deferred_turn_usage(run_id, attempt: RETRY_WAITS.length + 1, final: true)
    end
  end
end
