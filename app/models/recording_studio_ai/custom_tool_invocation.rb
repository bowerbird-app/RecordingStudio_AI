# frozen_string_literal: true

module RecordingStudioAI
  class CustomToolInvocation < ApplicationRecord
    include TerminalImmutability
    include InstrumentedLifecycle

    self.table_name = "recording_studio_ai_custom_tool_invocations"

    STATUSES = {
      requested: "requested",
      awaiting_confirmation: "awaiting_confirmation",
      authorized: "authorized",
      running: "running",
      completed: "completed",
      denied: "denied",
      rejected: "rejected",
      failed: "failed",
      cancelled: "cancelled"
    }.freeze

    enum :status, STATUSES, validate: true

    belongs_to :run,
               class_name: "RecordingStudioAI::Run",
               foreign_key: :run_id,
               inverse_of: :custom_tool_invocations

    belongs_to :requested_by_attempt,
               class_name: "RecordingStudioAI::Attempt",
               foreign_key: :requested_by_attempt_id,
               optional: true,
               inverse_of: :requested_custom_tool_invocations

    belongs_to :continued_by_attempt,
               class_name: "RecordingStudioAI::Attempt",
               foreign_key: :continued_by_attempt_id,
               optional: true,
               inverse_of: :continued_custom_tool_invocations

    validates :run, :tool_key, :tool_version, :status, presence: true
    validates :cost_category, inclusion: { in: %w[negligible low medium high] }, allow_nil: true
    validates :latency_category, inclusion: { in: %w[instant fast slow] }, allow_nil: true
    validates :confirmation_status, inclusion: { in: %w[not_required pending confirmed rejected expired] }, allow_nil: true
    validate :attempts_belong_to_same_run

    class << self
      def terminal_statuses
        %w[completed denied rejected failed cancelled]
      end

      def immutable_after_terminal_columns
        %i[
          run_id
          requested_by_attempt_id
          continued_by_attempt_id
          provider_tool_call_id
          tool_key
          tool_version
          tool_name_snapshot
          read_only
          destructive
          requires_confirmation
          idempotent
          cost_category
          latency_category
          confirmation_status
          confirmed_by_type
          confirmed_by_id
          confirmed_at
          result_summary
          started_at
          completed_at
          latency_ms
          error_category
          error_code
          error_message
        ]
      end
    end

    private

    def attempts_belong_to_same_run
      if requested_by_attempt && requested_by_attempt.run_id != run_id
        errors.add(:requested_by_attempt_id, "must belong to the same run")
      end

      return unless continued_by_attempt && continued_by_attempt.run_id != run_id

      errors.add(:continued_by_attempt_id, "must belong to the same run")
    end
  end
end
