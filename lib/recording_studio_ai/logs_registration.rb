# frozen_string_literal: true

module RecordingStudioAI
  module LogsRegistration
    ATTEMPT_MODEL = "RecordingStudioAI::Attempt"
    TOOL_MODEL = "RecordingStudioAI::CustomToolInvocation"
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

    module_function

    def register!
      return unless defined?(RecordingStudioLogs)

      register_attempts!
      register_tool_invocations!
      RecordingStudioLogs.finalize!
    end

    def register_attempts!
      RecordingStudioLogs.register(**ATTEMPT_LOG)
    end

    def register_tool_invocations!
      RecordingStudioLogs.register(**TOOL_LOG)
    end
  end
end
