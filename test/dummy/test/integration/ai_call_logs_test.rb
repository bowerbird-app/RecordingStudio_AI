# frozen_string_literal: true

require "test_helper"

class AICallLogsTest < ActiveSupport::TestCase
  setup do
    @original_flag = RecordingStudioAI.configuration.logs_summaries_enabled
    RecordingStudioAI.configuration.logs_summaries_enabled = false
    RecordingStudioAI::LogsRegistration.register!
    @user = User.create!(
      email: "ai-logs-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    @workspace = Workspace.create!(name: "AI logs #{SecureRandom.hex(4)}")
    @root = RecordingStudio.root_recording_for(@workspace)
    @day = Date.new(2026, 10, 1)
    clear_runs!
  end

  teardown do
    RecordingStudioAI.configuration.logs_summaries_enabled = @original_flag
  end

  test "flag stays off and Metrics still reads raw runs" do
    refute RecordingStudioAI::LogsRegistration.summaries_enabled?
    assert_equal RecordingStudioAI::Run, RecordingStudioMetrics.find("ai_runs.over_time").model
  end

  test "registers unpartitioned indefinite attempt and tool logs" do
    connection = RecordingStudioAI::Attempt.connection
    %w[
      recording_studio_ai_attempts
      recording_studio_ai_custom_tool_invocations
      recording_studio_ai_attempt_day_summaries
      recording_studio_ai_tool_call_day_summaries
    ].each do |table|
      relkind = connection.select_value("SELECT relkind FROM pg_class WHERE relname = #{connection.quote(table)}")
      assert_equal "r", relkind, table
    end
    assert_equal "id", connection.primary_key("recording_studio_ai_attempts")

    attempt_log = RecordingStudioLogs.registry.log_for("RecordingStudioAI::Attempt")
    assert_nil attempt_log.partition_interval
    assert attempt_log.indefinite?
    assert_equal :root_recording_id, attempt_log.root_column
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

  test "rebuild writes daily counts that match raw attempts and tool calls" do
    run = create_run!
    2.times do |index|
      run.attempts.create!(
        sequence: index + 1, kind: index.zero? ? "primary" : "retry", status: "completed",
        provider: "openai", model: "gpt-test", latency_ms: 10 + index
      )
    end
    run.attempts.create!(
      sequence: 3, kind: "fallback", status: "failed", provider: "gemini", model: "gemini-test", latency_ms: 40
    )
    run.custom_tool_invocations.create!(
      tool_key: "dummy_echo_tool", tool_version: 1, status: "completed", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true, latency_ms: 5
    )
    run.custom_tool_invocations.create!(
      tool_key: "dummy_echo_tool", tool_version: 1, status: "failed", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true, latency_ms: 8
    )

    stamp_created_at!(RecordingStudioAI::Attempt, Time.utc(2026, 10, 1, 12))
    stamp_created_at!(RecordingStudioAI::CustomToolInvocation, Time.utc(2026, 10, 1, 12))

    RecordingStudioAI::Services::RebuildAiCallLogSummaries.call(day: @day)

    counts = RecordingStudioAI::AttemptDaySummary.where(day: @day)
    assert_equal 3, counts.sum(:call_count)
    assert_equal 2, counts.where(provider: "openai", model: "gpt-test", status: "completed").sum(:call_count)
    assert_equal 1, counts.where(status: "failed").sum(:call_count)
    assert_equal 61, counts.sum(:latency_sum_ms)

    tools = RecordingStudioAI::ToolCallDaySummary.where(day: @day)
    assert_equal 2, tools.sum(:tool_call_count)
    assert_equal 1, tools.where(tool_key: "dummy_echo_tool", status: "completed").sum(:tool_call_count)
    assert_equal 1, tools.where(status: "failed").sum(:tool_call_count)
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

  def stamp_created_at!(model, time)
    model.update_all(created_at: time, updated_at: time)
  end

  def clear_runs!
    connection = RecordingStudioAI::LogsRegistration.logging_connection
    return unless connection.data_source_exists?("recording_studio_logs_aggregation_runs")

    connection.execute("DELETE FROM #{connection.quote_table_name('recording_studio_logs_aggregation_runs')}")
  end
end
