# frozen_string_literal: true

require "test_helper"

class AICallLogsTest < ActiveSupport::TestCase
  setup do
    RecordingStudioAI::LogsRegistration.register!
    @user = User.create!(
      email: "ai-logs-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    @workspace = Workspace.create!(name: "AI logs #{SecureRandom.hex(4)}")
    @root = RecordingStudio.root_recording_for(@workspace)
  end

  test "Metrics still reads raw runs" do
    assert_equal RecordingStudioAI::Run, RecordingStudioMetrics.find("ai_runs.over_time").model
  end

  test "registers unpartitioned indefinite attempt and tool logs" do
    connection = RecordingStudioAI::Attempt.connection
    %w[
      recording_studio_ai_attempts
      recording_studio_ai_custom_tool_invocations
    ].each do |table|
      relkind = connection.select_value("SELECT relkind FROM pg_class WHERE relname = #{connection.quote(table)}")
      assert_equal "r", relkind, table
    end
    refute connection.data_source_exists?("recording_studio_ai_attempt_day_summaries")
    refute connection.data_source_exists?("recording_studio_ai_tool_call_day_summaries")
    assert_equal "id", connection.primary_key("recording_studio_ai_attempts")

    attempt_log = RecordingStudioLogs.registry.log_for("RecordingStudioAI::Attempt")
    tool_log = RecordingStudioLogs.registry.log_for("RecordingStudioAI::CustomToolInvocation")
    assert_nil attempt_log.partition_interval
    assert attempt_log.indefinite?
    assert_equal :root_recording_id, attempt_log.root_column
    assert_nil tool_log.partition_interval
    assert tool_log.indefinite?
    assert_equal :root_recording_id, tool_log.root_column
    assert_empty RecordingStudioLogs.registry.aggregations_for(attempt_log)
    assert_empty RecordingStudioLogs.registry.aggregations_for(tool_log)
  end

  test "new rows stamp root_recording_id from the run" do
    run = create_run!
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed", provider: "openai",
                                   model: "gpt-test", latency_ms: 12)
    invocation = run.custom_tool_invocations.create!(
      tool_key: "dummy_echo_tool", tool_version: 1, status: "completed", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true, latency_ms: 3
    )

    assert_equal @root.id, attempt.root_recording_id
    assert_equal @root.id, invocation.root_recording_id
  end

  private

  def create_run!
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: "completed",
      resolved_provider: "openai",
      resolved_model: "gpt-test",
      root_recording_id: @root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user"
    )
  end
end
