# frozen_string_literal: true

require "test_helper"

class LogsRegistrationTest < RecordingStudioAI::Test::PersistenceCase
  def persistence_schema
    :hardened
  end

  def reset_persistence_columns?
    true
  end

  def test_registers_unpartitioned_indefinite_call_logs
    RecordingStudioAI::LogsRegistration.register!

    attempt_log = RecordingStudioLogs.registry.log_for(RecordingStudioAI::Attempt)
    tool_log = RecordingStudioLogs.registry.log_for(RecordingStudioAI::CustomToolInvocation)

    assert_equal :created_at, attempt_log.timestamp_column
    assert_nil attempt_log.partition_interval
    assert attempt_log.indefinite?
    assert_equal :root_recording_id, attempt_log.root_column
    assert_equal :indefinite, RecordingStudioAI::LogsRegistration::ATTEMPT_LOG[:retention]
    assert_equal :created_at, tool_log.timestamp_column
    assert_nil tool_log.partition_interval
    assert tool_log.indefinite?
    assert_equal :indefinite, RecordingStudioAI::LogsRegistration::TOOL_LOG[:retention]
    assert_equal :root_recording_id, tool_log.root_column
    assert_empty RecordingStudioLogs.registry.aggregations_for(attempt_log)
    assert_empty RecordingStudioLogs.registry.aggregations_for(tool_log)

    RecordingStudioAI::LogsRegistration::FORBIDDEN_ATTEMPT_COLUMNS.each do |column|
      refute_includes RecordingStudioAI::LogsRegistration::ATTEMPT_AGGREGATABLE.keys, column
    end
    RecordingStudioAI::LogsRegistration::FORBIDDEN_TOOL_COLUMNS.each do |column|
      refute_includes RecordingStudioAI::LogsRegistration::TOOL_AGGREGATABLE.keys, column
    end
    %i[error_message arguments result confirmed_by_id].each do |column|
      refute_includes RecordingStudioAI::LogsRegistration::ATTEMPT_AGGREGATABLE.keys, column
      refute_includes RecordingStudioAI::LogsRegistration::TOOL_AGGREGATABLE.keys, column
    end
  end

  def test_in_place_root_column_backfill_and_create_stamp
    connection = ActiveRecord::Base.connection
    assert connection.column_exists?(:recording_studio_ai_attempts, :root_recording_id)
    assert connection.column_exists?(:recording_studio_ai_custom_tool_invocations, :root_recording_id)

    root_recording_id = create_recording_id
    run = RecordingStudioAI::Run.create!(
      operation: "generation", status: "pending", root_recording_id: root_recording_id,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "pending")
    invocation = run.custom_tool_invocations.create!(
      tool_key: "lookup", tool_version: 1, status: "requested", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true
    )

    assert_equal root_recording_id, attempt.root_recording_id
    assert_equal root_recording_id, invocation.root_recording_id

    connection.execute(<<~SQL.squish)
      UPDATE recording_studio_ai_attempts SET root_recording_id = NULL WHERE id = #{attempt.id}
    SQL
    ActiveRecord::Migration.suppress_messages { AddRootRecordingIdToRecordingStudioAICallLogs.new.up }
    attempt.reload
    assert_equal root_recording_id, attempt.root_recording_id
  end
end
