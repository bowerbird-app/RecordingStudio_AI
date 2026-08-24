# frozen_string_literal: true

require "active_job"

module RecordingStudioAI
  class ResponseCleanupJob < ::ActiveJob::Base
    queue_as :default

    def perform
      ResponseCleanup.call
    end
  end
end