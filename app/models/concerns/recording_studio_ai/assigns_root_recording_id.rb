# frozen_string_literal: true

module RecordingStudioAI
  module AssignsRootRecordingId
    extend ActiveSupport::Concern

    included do
      before_validation :assign_root_recording_id, on: :create
    end

    private

    def assign_root_recording_id
      return if root_recording_id.present?

      self.root_recording_id = run&.root_recording_id
    end
  end
end
