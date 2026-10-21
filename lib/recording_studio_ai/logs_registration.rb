# frozen_string_literal: true

module RecordingStudioAI
  module LogsRegistration
    ATTEMPT_MODEL = "RecordingStudioAI::Attempt"
    TOOL_MODEL = "RecordingStudioAI::CustomToolInvocation"
    CALL_COUNTS = "ai/call_counts"
    TOOL_CALLS = "ai/tool_calls"
    OWNER = "RecordingStudioAI"
    FORBIDDEN_ATTEMPT_COLUMNS = %i[
      error_message metadata provider_request_id attachment_content_types
    ].freeze
    FORBIDDEN_TOOL_COLUMNS = %i[
      arguments result result_summary error_message metadata
      confirmed_by_type confirmed_by_id provider_tool_call_id
    ].freeze
    ATTEMPT_AGGREGATABLE = {
      root_recording_id: { filter: [:eq], group: true },
      provider: { filter: [:eq], group: true },
      model: { filter: [:eq], group: true },
      status: { filter: [:eq], group: true },
      kind: { filter: [:eq], group: true },
      streaming: { filter: [:eq], group: true },
      error_category: { filter: [:eq], group: true },
      latency_ms: { measurements: %i[sum maximum] }
    }.freeze
    TOOL_AGGREGATABLE = {
      root_recording_id: { filter: [:eq], group: true },
      tool_key: { filter: [:eq], group: true },
      tool_version: { filter: [:eq], group: true },
      status: { filter: [:eq], group: true },
      read_only: { filter: [:eq], group: true },
      destructive: { filter: [:eq], group: true },
      latency_ms: { measurements: %i[sum maximum] }
    }.freeze
    ATTEMPT_LOG = {
      model: ATTEMPT_MODEL, timestamp_column: :created_at, partition_interval: nil,
      root_column: :root_recording_id, owner: OWNER, retention: :indefinite,
      aggregatable: ATTEMPT_AGGREGATABLE
    }.freeze
    TOOL_LOG = {
      model: TOOL_MODEL, timestamp_column: :created_at, partition_interval: nil,
      root_column: :root_recording_id, owner: OWNER, retention: :indefinite,
      aggregatable: TOOL_AGGREGATABLE
    }.freeze
    CALL_COUNTS_AGGREGATION = {
      source: ATTEMPT_MODEL, name: CALL_COUNTS,
      summary_model: "RecordingStudioAI::AttemptDaySummary", owner: OWNER,
      group_by: %i[root_recording_id provider model status],
      measurements: { call_count: :count, latency_sum_ms: { sum: :latency_ms },
                      latency_max_ms: { maximum: :latency_ms } }
    }.freeze
    TOOL_CALLS_AGGREGATION = {
      source: TOOL_MODEL, name: TOOL_CALLS,
      summary_model: "RecordingStudioAI::ToolCallDaySummary", owner: OWNER,
      group_by: %i[root_recording_id tool_key status],
      measurements: { tool_call_count: :count, latency_sum_ms: { sum: :latency_ms } }
    }.freeze

    module_function

    def summaries_enabled?
      RecordingStudioAI.configuration.logs_summaries_enabled
    end

    def logging_connection
      Attempt.connection
    end

    def register!
      return unless defined?(RecordingStudioLogs)

      register_attempts!
      register_tool_invocations!
      RecordingStudioLogs.finalize!
    end

    def register_attempts!
      RecordingStudioLogs.register(**ATTEMPT_LOG)
      RecordingStudioLogs.aggregate(**CALL_COUNTS_AGGREGATION)
    end

    def register_tool_invocations!
      RecordingStudioLogs.register(**TOOL_LOG)
      RecordingStudioLogs.aggregate(**TOOL_CALLS_AGGREGATION)
    end

    def call_counts_definition
      RecordingStudioLogs.registry.aggregation(CALL_COUNTS)
    end

    def tool_calls_definition
      RecordingStudioLogs.registry.aggregation(TOOL_CALLS)
    end
  end
end
