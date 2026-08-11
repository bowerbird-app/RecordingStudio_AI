# frozen_string_literal: true

module RecordingStudioAI
  class BatchItem < ApplicationRecord
    include TerminalImmutability
    include InstrumentedLifecycle

    self.table_name = "recording_studio_ai_batch_items"

    STATUSES = {
      pending: "pending",
      processing: "processing",
      completed: "completed",
      failed: "failed",
      cancelled: "cancelled",
      expired: "expired"
    }.freeze

    enum :status, STATUSES, validate: true

    belongs_to :batch,
               class_name: "RecordingStudioAI::Batch",
               foreign_key: :batch_id,
               inverse_of: :batch_items

    belongs_to :run,
               class_name: "RecordingStudioAI::Run",
               foreign_key: :run_id,
               inverse_of: :batch_item

    has_one :response,
            class_name: "RecordingStudioAI::Response",
            foreign_key: :batch_item_id,
            dependent: :destroy,
            inverse_of: :batch_item

    validates :batch, :run, :position, :reference, :status, presence: true
    validates :position, numericality: { greater_than_or_equal_to: 0 }
    validate :run_matches_batch_attribution

    class << self
      def terminal_statuses
        %w[completed failed cancelled expired]
      end

      def immutable_after_terminal_columns
        %i[
          batch_id
          run_id
          position
          reference
          provider_item_id
          started_at
          completed_at
          input_tokens
          output_tokens
          total_tokens
          cached_input_tokens
          reasoning_tokens
          cost_amount_microunits
          cost_currency
          cost_estimated
          finish_reason
          error_category
          error_code
          error_message
        ]
      end
    end

    private

    def run_matches_batch_attribution
      return unless batch && run

      errors.add(:run_id, "must belong to the batch root") if run.root_recording_id != batch.root_recording_id
      errors.add(:run_id, "must use the batch context") if run.context_recording_id != batch.context_recording_id
    end
  end
end
