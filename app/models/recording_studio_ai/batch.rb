# frozen_string_literal: true

module RecordingStudioAI
  class Batch < ApplicationRecord
    include TerminalImmutability
    include InstrumentedLifecycle

    self.table_name = "recording_studio_ai_batches"

    STATUSES = {
      preparing: "preparing",
      submitted: "submitted",
      processing: "processing",
      completed: "completed",
      partially_completed: "partially_completed",
      failed: "failed",
      cancelled: "cancelled",
      expired: "expired"
    }.freeze

    enum :status, STATUSES, validate: true

    has_many :batch_items,
             class_name: "RecordingStudioAI::BatchItem",
             foreign_key: :batch_id,
             dependent: :restrict_with_exception,
             inverse_of: :batch

    validates :status, :initiator_type, :initiator_id, :initiator_kind, :root_recording_id,
              presence: true

    class << self
      def terminal_statuses
        %w[completed partially_completed failed cancelled expired]
      end

      def immutable_after_terminal_columns
        %i[
          profile_key
          provider
          model
          provider_batch_id
          root_recording_id
          context_recording_id
          initiator_type
          initiator_id
          initiator_kind
          executor_type
          executor_id
          executor_kind
          impersonator_type
          impersonator_id
          execution_source
          request_id
          job_id
          submitted_at
          completed_at
          expires_at
          item_count
          completed_item_count
          failed_item_count
          cancelled_item_count
          input_tokens
          output_tokens
          total_tokens
          cached_input_tokens
          reasoning_tokens
          error_category
          error_code
          error_message
        ]
      end
    end
  end
end
