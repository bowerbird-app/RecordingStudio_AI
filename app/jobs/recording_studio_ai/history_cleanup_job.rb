# frozen_string_literal: true

require "active_job"

module RecordingStudioAI
  class HistoryCleanupJob < ::ActiveJob::Base
    queue_as :default

    def perform
      HistoryCleanup.call
    end
  end
end
