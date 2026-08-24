# frozen_string_literal: true

module RecordingStudioAI
  class Run < ApplicationRecord
    include TerminalImmutability
    include InstrumentedLifecycle

    self.table_name = "recording_studio_ai_runs"

    STATUSES = {
      pending: "pending",
      running: "running",
      completed: "completed",
      failed: "failed",
      cancelled: "cancelled"
    }.freeze

    enum :status, STATUSES, validate: true

    has_many :attempts,
             class_name: "RecordingStudioAI::Attempt",
             foreign_key: :run_id,
             dependent: :restrict_with_exception,
             inverse_of: :run

    has_many :custom_tool_invocations,
             class_name: "RecordingStudioAI::CustomToolInvocation",
             foreign_key: :run_id,
             dependent: :restrict_with_exception,
             inverse_of: :run

    has_one :batch_item,
            class_name: "RecordingStudioAI::BatchItem",
            foreign_key: :run_id,
            dependent: :restrict_with_exception,
            inverse_of: :run

    validates :operation, :status, :initiator_type, :initiator_id, :initiator_kind,
              :root_recording_id, presence: true
    validates :operation, inclusion: { in: %w[generation stream batch] }

    class << self
      def terminal_statuses
        %w[completed failed cancelled]
      end

      def immutable_after_terminal_columns
        %i[
          operation
          profile_key
          prompt_key
          prompt_version
          prompt_name_snapshot
          requested_provider
          resolved_provider
          resolved_model
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
          started_at
          completed_at
          latency_ms
          input_tokens
          output_tokens
          total_tokens
          cached_input_tokens
          reasoning_tokens
          attempt_count
          retry_count
          fallback_count
          custom_tool_invocation_count
          input_character_count
          output_character_count
          attachment_count
          attachment_total_bytes
          attachment_content_types
          citation_count
          web_search_requested
          web_search_used
          error_category
          error_code
          error_message
        ]
      end
    end
  end
end
