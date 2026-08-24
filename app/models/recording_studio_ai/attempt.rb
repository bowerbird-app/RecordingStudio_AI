# frozen_string_literal: true

module RecordingStudioAI
  class Attempt < ApplicationRecord
    include TerminalImmutability
    include InstrumentedLifecycle

    self.table_name = "recording_studio_ai_attempts"

    KINDS = {
      primary: "primary",
      retry: "retry",
      fallback: "fallback",
      continuation: "continuation"
    }.freeze

    STATUSES = {
      pending: "pending",
      running: "running",
      completed: "completed",
      failed: "failed",
      cancelled: "cancelled"
    }.freeze

    enum :kind, KINDS, validate: true
    enum :status, STATUSES, validate: true

    belongs_to :run,
               class_name: "RecordingStudioAI::Run",
               foreign_key: :run_id,
               inverse_of: :attempts

    has_many :requested_custom_tool_invocations,
             class_name: "RecordingStudioAI::CustomToolInvocation",
             foreign_key: :requested_by_attempt_id,
             dependent: :restrict_with_exception,
             inverse_of: :requested_by_attempt

    has_many :continued_custom_tool_invocations,
             class_name: "RecordingStudioAI::CustomToolInvocation",
             foreign_key: :continued_by_attempt_id,
             dependent: :restrict_with_exception,
             inverse_of: :continued_by_attempt

    has_one :response,
            class_name: "RecordingStudioAI::Response",
            foreign_key: :attempt_id,
            dependent: :destroy,
            inverse_of: :attempt

    validates :run, :sequence, :kind, :status, presence: true
    validates :sequence, numericality: { greater_than: 0 }

    class << self
      def terminal_statuses
        %w[completed failed cancelled]
      end

      def immutable_after_terminal_columns
        %i[
          run_id
          sequence
          kind
          profile_key
          provider
          model
          provider_request_id
          streaming
          started_at
          completed_at
          latency_ms
          input_tokens
          output_tokens
          total_tokens
          cached_input_tokens
          reasoning_tokens
          finish_reason
          retryable
          web_search_requested
          web_search_used
          citation_count
          attachment_count
          attachment_total_bytes
          attachment_content_types
          provider_file_count
          error_category
          error_code
          error_message
        ]
      end
    end
  end
end
