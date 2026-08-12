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
    assert_includes response.body, "href=\"/admin/screens/warnings\""
    assert_includes response.body, "Warnings"
    refute_includes response.body, "/admin/screens/recording_studio_ai_overview?anchor_url="
    refute_includes response.body, "/admin/recording_studio_ai/admin"
    assert_includes response.body, "Close"
    assert_includes response.body, "href=\"/\""
    refute_includes response.body, "Recording tree"
    refute_includes response.body, "AI Admin"
  end

  test "ai calls table filters by status" do
    authenticate_for_admin!

    create_run!(status: "completed", operation: "generation")
    create_run!(status: "failed", operation: "generation")

    get "/admin/screens/ai_calls/table", params: { run_status: "failed" }

    assert_response :success
    assert_includes response.body, "run_status=failed"
    assert_includes response.body, ">Failed<"
    refute_includes response.body, ">Completed<"
  end

  test "ai calls chart accepts a grouping filter" do
    authenticate_for_admin!

    get "/admin/screens/ai_calls/chart", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "AI calls trend"

    get "/admin/screens/ai_calls", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "group_by=month"
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

  test "estimated spend widget links to estimated spend screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/estimated_spend\""
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

  test "slow calls widget links to ai calls with slowest filter" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/ai_calls?slowest=1\""
  end

  test "warnings screen lists computed warnings" do
    authenticate_for_admin!

    get "/admin/screens/warnings"

    assert_response :success
    assert_includes response.body, "Warnings"
    refute_includes response.body, "Active warnings"
    refute_includes response.body, "Signal"
    refute_includes response.body, "Obvious usage, reliability, and spend signals."

    get "/admin/screens/warnings/table"

    assert_response :success
    refute_includes response.body, "Signal"
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
