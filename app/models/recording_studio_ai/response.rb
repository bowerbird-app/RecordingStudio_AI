# frozen_string_literal: true

module RecordingStudioAI
  class Response < ApplicationRecord
    self.table_name = "recording_studio_ai_responses"

    RESPONSE_TYPES = {
      generation: "generation",
      stream: "stream",
      batch_item: "batch_item",
      error: "error"
    }.freeze

    enum :response_type, RESPONSE_TYPES, validate: true

    belongs_to :attempt,
               class_name: "RecordingStudioAI::Attempt",
               foreign_key: :attempt_id,
               optional: true,
               inverse_of: :response

    belongs_to :batch_item,
               class_name: "RecordingStudioAI::BatchItem",
               foreign_key: :batch_item_id,
               optional: true,
               inverse_of: :response

    encrypts :raw_response
    encrypts :normalized_response
    encrypts :content_text

    validates :response_type, presence: true
    validate :belongs_to_attempt_or_batch_item

    scope :expired, ->(now = Time.current) { where(expires_at: ..now) }

    private

    def belongs_to_attempt_or_batch_item
      attempt_present = attempt_id.present?
      batch_item_present = batch_item_id.present?

      return if attempt_present ^ batch_item_present

      errors.add(:base, "exactly one of attempt_id or batch_item_id must be present")
    end
  end
end
