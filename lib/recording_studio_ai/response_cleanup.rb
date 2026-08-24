# frozen_string_literal: true

module RecordingStudioAI
  class ResponseCleanup
    def self.call(now: Time.current) = Response.expired(now).delete_all
  end
end