# frozen_string_literal: true

require "active_job"

module RecordingStudioAI
  class BatchSynchronizationJob < ::ActiveJob::Base
    queue_as :default

    TERMINAL_STATUSES = %w[completed partially_completed failed cancelled expired].freeze

    def perform(batch_id:, root_recording:, initiator:, initiator_kind: nil, context_recording: nil, executor: nil,
          impersonator: nil, execution_source: :job, request_id: nil)
      arguments = {
        batch_id: batch_id,
        root_recording: root_recording,
        initiator: initiator,
        initiator_kind: initiator_kind,
        context_recording: context_recording,
        executor: executor,
        impersonator: impersonator,
        execution_source: execution_source,
        request_id: request_id,
        job_id: job_id
      }.compact
      response = RecordingStudioAI.refresh_batch(**arguments)
      reschedule(arguments.except(:job_id)) unless TERMINAL_STATUSES.include?(response.status)
      response
    end

    private

    def reschedule(arguments)
      self.class.set(wait: RecordingStudioAI.configuration.batch_synchronization_interval)
        .perform_later(**arguments)
    end
  end
end