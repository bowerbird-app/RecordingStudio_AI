# frozen_string_literal: true

require "test_helper"

class RecordingStudioAdminIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "admin-surface-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Admin surface workspace")
    @root_recording = RecordingStudio.root_recording_for(workspace)
    @original_access_recording_resolver = RecordingStudioAdmin.configuration.access_recording_resolver
    @original_required_access_role = RecordingStudioAdmin.configuration.required_access_role
    @original_access_management_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) { @root_recording }
    RecordingStudioAdmin.configuration.required_access_role = :view
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
  end

  teardown do
    RecordingStudioAdmin.configuration.access_recording_resolver = @original_access_recording_resolver
    RecordingStudioAdmin.configuration.required_access_role = @original_required_access_role
    RecordingStudioAccessible.configuration.access_management_authorizer = @original_access_management_authorizer
  end

  test "recording studio admin surface requires authentication" do
    get "/admin"

    assert_redirected_to new_user_session_path
  end

  test "recording studio admin surface includes recording studio ai section" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    refute_includes response.body, "href=\"/admin/screens/recording_studio_ai_overview\""
    refute_includes response.body, "href=\"/admin/screens/warnings\""
    refute_includes response.body, "/admin/screens/recording_studio_ai_overview?anchor_url="
    refute_includes response.body, "/admin/recording_studio_ai/admin"
    assert_includes response.body, "Close"
    assert_includes response.body, "href=\"/admin\""
    refute_includes response.body, "Recording tree"
    refute_includes response.body, "AI Admin"
  end

  test "methods guide documents the Recording Studio AI APIs" do
    authenticate_for_admin!

    get "/methods"

    assert_response :success
    assert_includes response.body, "Methods"
    assert_includes response.body, "RecordingStudioAI.generate"
    assert_includes response.body, "RecordingStudioAI.refresh_batch_async"
    assert_includes response.body, "href=\"/methods\""
  end

  test "ai playground shows batch items only in the batch tab" do
    authenticate_for_admin!

    get "/ai_playground"

    assert_response :success
    assert_equal 1, response.body.scan(/>Batch items</).size
    assert_equal 3, response.body.scan(/name="ai_playground\[batch_items\]\[\]"/).size
    assert_includes response.body, "Live response"
    assert_includes response.body, "ai-playground-stream#submit"
    assert_includes response.body, "data-ai-playground-stream-target=\"submit\""
    assert_includes response.body, "disabled:opacity-60"
    assert_includes File.read(Rails.root.join("app/javascript/controllers/ai_playground_stream_controller.js")),
                    "new FormData(event.currentTarget)"
  end

  test "ai calls table filters by status" do
    authenticate_for_admin!

    create_run!(status: "completed", operation: "generation")
    create_run!(status: "failed", operation: "generation")

    get "/admin/screens/ai_calls/table", params: { run_status: "failed" }

    assert_response :success
    assert_includes response.body, "run_status=failed"
    refute_includes response.body, ">Run<"
    assert_includes response.body, ">Failed<"
    refute_includes response.body, ">Completed<"
  end

  test "ai calls chart accepts a grouping filter" do
    authenticate_for_admin!
    create_run!(status: "completed", operation: "generation")

    get "/admin/screens/ai_calls/chart", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "AI calls trend"

    get "/admin/screens/ai_calls", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "group_by=month"
    assert_includes response.body, "controllers/recording_studio_admin/screen_filters_controller"
    assert_select "input[name='group_by']", count: 1
    assert_equal 1, response.body.scan(/name="run_status"/).size
  end

  test "ai calls defaults its date range to the last four weeks" do
    authenticate_for_admin!

    get "/admin/screens/ai_calls"

    assert_response :success
    assert_includes response.body, "value=\"last_4_weeks\""
  end

  test "ai calls chart marks increased failed and cancelled runs as unfavorable" do
    authenticate_for_admin!

    %w[failed cancelled].each do |status|
      create_run!(status: status, operation: "generation")

      get "/admin/screens/ai_calls/chart", params: { run_status: status }

      assert_response :success
      assert_includes response.body, "+100%"
      assert_includes response.body, "text-[var(--color-danger-background-color)]"
    end
  end

  test "ai calls applies a custom date range" do
    authenticate_for_admin!

    included_run = create_run!(status: "completed", operation: "generation", resolved_model: "date-range-included")
    excluded_run = create_run!(status: "failed", operation: "generation", resolved_model: "date-range-excluded")
    included_run.update!(created_at: 2.days.ago)
    excluded_run.update!(created_at: 2.months.ago)

    get "/admin/screens/ai_calls/table", params: {
      date_range_start: 3.days.ago.to_date.iso8601,
      date_range_end: Date.current.iso8601
    }

    assert_response :success
    assert_includes response.body, included_run.resolved_model
    refute_includes response.body, excluded_run.resolved_model
  end

  test "errors failed calls widget links to failed ai calls" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/ai_calls?run_status=failed\""
  end

  test "tool calls widget links to tool calls screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/tool_calls\""
  end

  test "registered custom tools widget and section link to the tools screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Custom tools"
    refute_includes response.body, "Current registry"
    assert_includes response.body, "href=\"/admin/screens/registered_custom_tools\""
  end

  test "registered custom tools screen shows definition and execution metrics" do
    authenticate_for_admin!

    get "/admin/screens/registered_custom_tools"

    assert_response :success
    assert_includes response.body, "Registered custom tools"
    assert_includes response.body, "Cost class"
    assert_includes response.body, "Calls / 30 days"
    refute_includes response.body, "Calls today"
    assert_includes response.body, "Success rate"
    assert_includes response.body, "Error rate"
    assert_includes response.body, "Average duration"
  end

  test "registered custom tool opens its definition in a modal" do
    authenticate_for_admin!

    get "/admin/screens/registered_custom_tools/table"

    assert_response :success
    assert_includes response.body, "Dummy Echo Tool"
    assert_includes response.body, "<button"
    assert_includes response.body, "data-modal-id=\"custom-tool-definition-dummy_echo_tool-1\""
    assert_includes response.body, "data-controller=\"flat-pack--modal\""
    assert_includes response.body, "#000000"
    assert_includes response.body, "Echoes input text with lightweight context metadata"
    refute_includes response.body, "Parameters"
    refute_includes response.body, "Repeated argument digests"

    get "/recording_studio_ai/admin/custom_tools/dummy_echo_tool/versions/1"

    assert_response :not_found
  end

  test "tool calls defaults its date range to the last four weeks" do
    authenticate_for_admin!

    get "/admin/screens/tool_calls"

    assert_response :success
    assert_includes response.body, "value=\"last_4_weeks\""
  end

  test "ai call tool-call count links to that run's tool calls" do
    authenticate_for_admin!
    selected_run = create_run!(status: "completed", operation: "generation")
    other_run = create_run!(status: "completed", operation: "generation")
    selected_run.custom_tool_invocations.create!(
      tool_key: "selected_tool",
      tool_version: 1,
      status: "completed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    other_run.custom_tool_invocations.create!(
      tool_key: "other_tool",
      tool_version: 1,
      status: "completed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    selected_run.update_column(:custom_tool_invocation_count, 1)
    other_run.update_column(:custom_tool_invocation_count, 1)

    get "/admin/screens/ai_calls/table"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/tool_calls?run_id=#{selected_run.id}\""

    get "/admin/screens/tool_calls/table", params: { run_id: selected_run.id }

    assert_response :success
    assert_includes response.body, "selected_tool"
    refute_includes response.body, "other_tool"
  end

  test "registered tool mini chart links to last thirty days of matching ai calls" do
    authenticate_for_admin!
    RecordingStudioAI.tools.register(**DUMMY_TOOLS.first) unless RecordingStudioAI.tools.fetch("dummy_echo_tool", version: 1)
    matching_run = create_run!(status: "completed", operation: "generation", resolved_model: "matching-tool-run")
    other_run = create_run!(status: "completed", operation: "generation", resolved_model: "other-tool-run")
    matching_run.custom_tool_invocations.create!(tool_key: "dummy_echo_tool", tool_version: 1, status: "completed", read_only: true, destructive: false, requires_confirmation: false, idempotent: true)
    other_run.custom_tool_invocations.create!(tool_key: "other_tool", tool_version: 1, status: "completed", read_only: true, destructive: false, requires_confirmation: false, idempotent: true)

    get "/admin/screens/registered_custom_tools/table"

    assert_response :success
    assert_includes response.body, "flat-pack--chart-series-value"
    assert_includes response.body, "date_range_preset=last_30_days"
    assert_includes response.body, "custom_tool_key=dummy_echo_tool"

    get "/admin/screens/ai_calls/table", params: { date_range_preset: "last_30_days", custom_tool_key: "dummy_echo_tool" }

    assert_response :success
    assert_includes response.body, "matching-tool-run"
    refute_includes response.body, "other-tool-run"
  end

  test "ai call attempt count links to attempts filtered and ordered by sequence" do
    authenticate_for_admin!
    selected_run = create_run!(status: "completed", operation: "generation")
    other_run = create_run!(status: "completed", operation: "generation")
    selected_run.attempts.create!(sequence: 2, kind: "retry", status: "completed", model: "selected-second")
    selected_run.attempts.create!(sequence: 1, kind: "primary", status: "failed", model: "selected-first")
    other_run.attempts.create!(sequence: 1, kind: "primary", status: "completed", model: "other-attempt")
    selected_run.update_column(:attempt_count, 2)
    other_run.update_column(:attempt_count, 1)

    get "/admin/screens/ai_calls/table"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/attempts?run_id=#{selected_run.id}\""

    get "/admin/screens/attempts/table", params: { run_id: selected_run.id }

    assert_response :success
    assert_includes response.body, "selected-first"
    assert_includes response.body, "selected-second"
    refute_includes response.body, "other-attempt"
    assert_operator response.body.index("selected-first"), :<, response.body.index("selected-second")
  end

  test "attempts defaults to four weeks and filters by provider and kind" do
    authenticate_for_admin!
    openai_run = create_run!(status: "completed", operation: "generation")
    google_run = create_run!(status: "completed", operation: "generation")
    openai_run.attempts.create!(sequence: 1, kind: "retry", status: "completed", provider: "openai", model: "attempt-openai-retry")
    google_run.attempts.create!(sequence: 1, kind: "primary", status: "completed", provider: "google", model: "attempt-google-primary")

    get "/admin/screens/attempts"

    assert_response :success
    assert_includes response.body, "value=\"last_4_weeks\""
    assert_includes response.body, "attempt_status"
    assert_includes response.body, "provider"

    get "/admin/screens/attempts/table", params: { provider: "openai", kind: "retry" }

    assert_response :success
    assert_includes response.body, "attempt-openai-retry"
    refute_includes response.body, "attempt-google-primary"
  end

  test "retry rate by model widget links to attempts" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Retry rate by model"
    assert_includes response.body, "href=\"/admin/screens/attempts\""
  end

  test "retry rate by model ranks the top three models by retried run share" do
    create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-100").update_column(:retry_count, 1)

    2.times.with_index do |index|
      create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-50").update_column(:retry_count, index.zero? ? 1 : 0)
    end
    4.times.with_index do |index|
      create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-25").update_column(:retry_count, index.zero? ? 1 : 0)
    end
    create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-0").update_column(:retry_count, 0)

    rows = AdminScreens::RecordingStudioAIWidgets.retry_rate_by_model_rows(
      RecordingStudioAI::Run.where(root_recording_id: @root_recording.id)
    )

    assert_equal [["retry-rate-100", 100.0], ["retry-rate-50", 50.0], ["retry-rate-25", 25.0]], rows
  end

  test "retry rate by model widget treats increased retries as unfavorable" do
    authenticate_for_admin!
    current_run = create_run!(status: "completed", operation: "generation", resolved_model: "retry-widget-current")
    previous_run = create_run!(status: "completed", operation: "generation", resolved_model: "retry-widget-previous")
    current_run.update_columns(retry_count: 2, created_at: 1.day.ago)
    previous_run.update_columns(retry_count: 1, created_at: 45.days.ago)

    get "/admin"

    assert_response :success
    assert_includes response.body, ">2<"
    assert_includes response.body, "+100%"
    assert_includes response.body, "text-[var(--color-danger-background-color)]"
  end

  test "tool calls table filters by status" do
    authenticate_for_admin!

    run = create_run!(status: "completed", operation: "generation")
    run.custom_tool_invocations.create!(
      tool_key: "completed_tool",
      tool_version: 1,
      status: "completed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    run.custom_tool_invocations.create!(
      tool_key: "failed_tool",
      tool_version: 1,
      status: "failed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )

    get "/admin/screens/tool_calls/table", params: { tool_status: "failed" }

    assert_response :success
    assert_includes response.body, "tool_status=failed"
    assert_includes response.body, "failed_tool"
    refute_includes response.body, "completed_tool"
  end

  test "tool calls chart accepts a grouping filter" do
    authenticate_for_admin!

    get "/admin/screens/tool_calls/chart", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "Custom tool calls trend"
  end

  test "tool calls chart marks increased denied, failed, and rejected calls as unfavorable" do
    authenticate_for_admin!
    run = create_run!(status: "completed", operation: "generation")

    %w[denied failed rejected].each do |status|
      run.custom_tool_invocations.create!(
        tool_key: "#{status}_tool",
        tool_version: 1,
        status: status,
        read_only: true,
        destructive: false,
        requires_confirmation: false,
        idempotent: true
      )

      get "/admin/screens/tool_calls/chart", params: { tool_status: status }

      assert_response :success
      assert_includes response.body, "+100%"
      assert_includes response.body, "text-[var(--color-danger-background-color)]"
    end
  end

  test "estimated spend widget links to estimated spend screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/estimated_spend\""
  end

  test "estimated spend defaults to the last four weeks grouped by day" do
    authenticate_for_admin!

    get "/admin/screens/estimated_spend"

    assert_response :success
    assert_select "input[value='Last 4 weeks']", minimum: 1
  end

  test "estimated spend treats decreased token usage as favorable" do
    assert_equal :down, AdminScreens::RecordingStudioAIEstimatedSpendScreen.summary.change_good_when
  end

  test "estimated spend table filters by model" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "gpt-5",
      resolved_provider: "openai",
      total_tokens: 1200,
      input_tokens: 700,
      output_tokens: 500
    )
    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "gemini-2.5-pro",
      resolved_provider: "google",
      total_tokens: 900,
      input_tokens: 500,
      output_tokens: 400
    )

    get "/admin/screens/estimated_spend/table", params: { model: "gpt-5" }

    assert_response :success
    assert_includes response.body, "model=gpt-5"
    assert_includes response.body, "gpt-5"
    refute_includes response.body, "gemini-2.5-pro"
  end

  test "estimated spend table filters by status and token range" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "token-range-included",
      total_tokens: 1_500
    )
    create_run!(
      status: "failed",
      operation: "generation",
      resolved_model: "token-range-excluded-status",
      total_tokens: 1_500
    )
    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "token-range-excluded-minimum",
      total_tokens: 500
    )

    get "/admin/screens/estimated_spend/table", params: {
      run_status: "completed",
      min_tokens: 1_000,
      max_tokens: 2_000
    }

    assert_response :success
    assert_includes response.body, "token-range-included"
    refute_includes response.body, "token-range-excluded-status"
    refute_includes response.body, "token-range-excluded-minimum"
  end

  test "slow calls widget links to ai calls with slowest filter" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/ai_calls?slowest=1\""
  end

  test "warnings screen is not registered" do
    authenticate_for_admin!

    get "/admin/screens/warnings"

    assert_response :not_found
  end

  test "ai calls table slowest filter orders by latency descending" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: 7011,
      resolved_model: "latency-model-7011"
    )
    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: 9011,
      resolved_model: "latency-model-9011"
    )
    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: 8011,
      resolved_model: "latency-model-8011"
    )
    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: nil,
      resolved_model: "latency-model-nil"
    )

    get "/admin/screens/ai_calls/table", params: { slowest: "1" }

    assert_response :success
    assert_includes response.body, "slowest=1"

    index_9011 = response.body.index("latency-model-9011")
    index_8011 = response.body.index("latency-model-8011")
    index_7011 = response.body.index("latency-model-7011")
    index_nil = response.body.index("latency-model-nil")

    assert index_9011, "expected to find highest-latency model row in response"
    assert index_8011, "expected to find middle-latency model row in response"
    assert index_7011, "expected to find lowest-latency model row in response"
    assert_operator index_9011, :<, index_8011
    assert_operator index_8011, :<, index_7011
    assert_nil index_nil, "expected nil-latency rows to be excluded when slowest filter is enabled"
  end

  private

  def authenticate_for_admin!
    grant_result = RecordingStudioAccessible.grant_access(recording: @root_recording, actor: @user, role: :view)
    assert grant_result.success?, grant_result.error
    sign_in @user
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: @root_recording.id,
        return_to: "/"
      }
    }
    follow_redirect!
  end

  def create_run!(status:, operation:, resolved_model: nil, resolved_provider: nil,
                  total_tokens: nil, input_tokens: nil, output_tokens: nil, latency_ms: nil)
    RecordingStudioAI::Run.create!(
      operation: operation,
      status: status,
      resolved_model: resolved_model,
      resolved_provider: resolved_provider,
      latency_ms: latency_ms,
      root_recording_id: @root_recording.id,
      context_recording_id: @root_recording.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user",
      total_tokens: total_tokens,
      input_tokens: input_tokens,
      output_tokens: output_tokens
    )
  end
end
