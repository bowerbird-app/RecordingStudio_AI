# frozen_string_literal: true

require "test_helper"

class RecordingStudioAIAdminTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "admin-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @visible_workspace = Workspace.create!(name: "Visible admin workspace")
    @hidden_workspace = Workspace.create!(name: "Hidden admin workspace")
    @visible_root = RecordingStudio.root_recording_for(@visible_workspace)
    @hidden_root = RecordingStudio.root_recording_for(@hidden_workspace)
    @original_root_resolver = RecordingStudioAI.configuration.admin_visible_roots_resolver
    @original_authorization_handler = RecordingStudioAI.configuration.authorization_handler
    RecordingStudioAI.configuration.admin_visible_roots_resolver = ->(actor:, controller:) { [ @visible_root.id ] }
  end

  teardown do
    RecordingStudioAI.configuration.admin_visible_roots_resolver = @original_root_resolver
    RecordingStudioAI.configuration.authorization_handler = @original_authorization_handler
  end

  test "admin routes require host authentication" do
    get "/recording_studio_ai/admin/runs"

    assert_redirected_to new_user_session_path
  end

  test "run index is root scoped and hides sensitive identifiers without permission" do
    visible_run = create_run(@visible_root, correlation_id: "visible-sensitive-correlation")
    hidden_run = create_run(@hidden_root, correlation_id: "hidden-sensitive-correlation")
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      action != "recording_studio_ai.view_sensitive_execution"
    end
    sign_in @user

    get "/recording_studio_ai/admin/runs"

    assert_response :success
    assert_includes response.body, "Run #{visible_run.id}"
    refute_includes response.body, "Run #{hidden_run.id}"
    refute_includes response.body, "visible-sensitive-correlation"
    refute_includes response.body, "hidden-sensitive-correlation"
    refute_includes response.body.downcase, "replay"
  end

  test "run detail hides metadata and attempt errors without sensitive permission" do
    run = create_run(@visible_root, correlation_id: "redacted-run")
    run.update_column(:metadata, { "marker" => "run-secret-marker" })
    run.attempts.create!(
      sequence: 1,
      kind: "primary",
      status: "failed",
      metadata: { "marker" => "attempt-secret-marker" },
      error_category: "provider_error",
      error_code: "attempt-secret-code",
      error_message: "attempt-secret-message"
    )
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      action != "recording_studio_ai.view_sensitive_execution"
    end
    sign_in @user

    get "/recording_studio_ai/admin/runs/#{run.id}"

    assert_response :success
    refute_includes response.body, "run-secret-marker"
    refute_includes response.body, "attempt-secret-marker"
    refute_includes response.body, "attempt-secret-code"
    refute_includes response.body, "attempt-secret-message"
  end

  test "overview renders with FlatPack host chrome" do
    sign_in @user

    get "/recording_studio_ai/admin"

    assert_response :success
    assert_includes response.body, "AI administration"
    assert_includes response.body, "AI activity"
    %w[Runs Errors Tokens Spend].each { |title| assert_includes response.body, title }
    assert_includes response.body, "Custom-tool calls"
    assert_includes response.body, "Batch items"
  end

  test "out-of-scope run IDs return not found" do
    hidden_run = create_run(@hidden_root, correlation_id: "hidden-run")
    sign_in @user

    get "/recording_studio_ai/admin/runs/#{hidden_run.id}"

    assert_response :not_found
  end

  test "identity snapshot search requires sensitive permission" do
    run = create_run(
      @visible_root, correlation_id: "ordinary-correlation",
      initiator_snapshot: { "label" => "classified-handle" }
    )
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      action != "recording_studio_ai.view_sensitive_execution"
    end
    sign_in @user

    get "/recording_studio_ai/admin/runs", params: { q: "classified-handle" }
    assert_response :success
    refute_includes response.body, "Run #{run.id}"

    RecordingStudioAI.configuration.authorization_handler = ->(**) { true }
    get "/recording_studio_ai/admin/runs", params: { q: "classified-handle" }
    assert_response :success
    assert_includes response.body, "Run #{run.id}"
  end

  test "uuid actor IDs round trip without coercion" do
    run = create_run(@visible_root, correlation_id: "uuid-actor")

    assert_equal @user.id, run.reload.initiator_id
  end

  test "retained response requires sensitive and retained-response permissions" do
    run = create_run(@visible_root, correlation_id: "retained-run")
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed")
    retained = attempt.create_response!(
      response_type: "generation",
      raw_response: JSON.generate(id: "provider-response"),
      normalized_response: JSON.generate(text: "sanitized output"),
      content_text: "sanitized output",
      byte_size: 16,
      complete: true,
      truncated: false,
      expires_at: 1.day.from_now
    )
    actions = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      actions << action
      action != "recording_studio_ai.view_retained_response"
    end
    sign_in @user

    get "/recording_studio_ai/admin/retained_responses/#{retained.id}"

    assert_response :not_found
    assert_includes actions, "recording_studio_ai.view_sensitive_execution"
    assert_includes actions, "recording_studio_ai.view_retained_response"
  end

  test "hidden retained responses are rejected before content authorization" do
    run = create_run(@hidden_root, correlation_id: "hidden-retained-run")
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed")
    retained = attempt.create_response!(response_type: "generation", expires_at: 1.day.from_now)
    actions = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      actions << action
      true
    end
    sign_in @user

    get "/recording_studio_ai/admin/retained_responses/#{retained.id}"

    assert_response :not_found
    refute_includes actions, "recording_studio_ai.view_sensitive_execution"
    refute_includes actions, "recording_studio_ai.view_retained_response"
  end

  test "all administration screen families render from persisted data" do
    run = create_run(@visible_root, correlation_id: "screen-family-run")
    attempt = run.attempts.create!(
      sequence: 1, kind: "primary", status: "completed", provider_request_id: "provider-admin-request"
    )
    retained = attempt.create_response!(
      response_type: "generation",
      normalized_response: JSON.generate(text: "retained output"),
      content_text: "retained output",
      expires_at: 1.day.from_now
    )
    batch = RecordingStudioAI::Batch.create!(
      status: "preparing",
      correlation_id: "screen-family-batch",
      root_recording_id: @visible_root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user"
    )
    tool = RecordingStudioAI.tools.register(
      key: "admin_tool_#{SecureRandom.hex(4)}",
      version: 1,
      name: "Admin test tool",
      description: "Exercises the administration definition view.",
      use_when: "Testing administration",
      do_not_use_when: "Outside tests",
      parameters: [],
      returns: "A test result",
      cost: :negligible,
      latency: :instant,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Test executor",
      executor: ->(**) { "ok" }
    )
    run.custom_tool_invocations.create!(
      requested_by_attempt: attempt,
      tool_key: tool.key,
      tool_version: tool.version,
      tool_name_snapshot: tool.name,
      status: "failed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      cost_category: "negligible",
      latency_category: "instant",
      error_category: "tool_error",
      error_code: "admin_tool_failed",
      metadata: { "safe" => true }
    )
    sign_in @user

    paths = [
      "/recording_studio_ai/admin",
      "/recording_studio_ai/admin/runs",
      "/recording_studio_ai/admin/runs/#{run.id}",
      "/recording_studio_ai/admin/custom_tools",
      "/recording_studio_ai/admin/custom_tools/#{tool.key}/versions/#{tool.version}",
      "/recording_studio_ai/admin/provider_native_tools",
      "/recording_studio_ai/admin/batches",
      "/recording_studio_ai/admin/batches/#{batch.id}",
      "/recording_studio_ai/admin/retained_responses/#{retained.id}",
      "/recording_studio_ai/admin/runs?retained_response=1"
    ]

    paths.each do |path|
      get path
      assert_response :success, path
    end
    assert_includes response.body, "Run #{run.id}"

    get "/recording_studio_ai/admin/runs"
    assert_includes response.body, "Minimum tokens"
    assert_includes response.body, "Minimum cost (microunits)"
    assert_includes response.body, "Attribution"
    assert_includes response.body, "retries"
    assert_includes response.body, "attachments"
    assert_includes response.body, "Input / output / total"

    get "/recording_studio_ai/admin/runs/#{run.id}"
    assert_includes response.body, "Started / completed"
    assert_includes response.body, "Attachment bytes / content types"
    assert_includes response.body, "Impersonator"
    assert_includes response.body, "Attachments / search / outcome"
    assert_includes response.body, "provider files"
    assert_includes response.body, "Metadata / error"
    assert_includes response.body, "confirmation not required"

    get "/recording_studio_ai/admin/runs", params: { q: "provider-admin-request" }
    assert_response :success
    assert_includes response.body, "Run #{run.id}"

    get "/recording_studio_ai/admin/custom_tools"
    assert_includes response.body, "Average / p95 duration"

    get "/recording_studio_ai/admin/custom_tools/#{tool.key}/versions/#{tool.version}"
    assert_includes response.body, "Usage by day"
    assert_includes response.body, "Calls per run"
    assert_includes response.body, "Common errors"
    assert_includes response.body, "admin_tool_failed"
  end

  private

  def create_run(root, correlation_id:, initiator_snapshot: nil)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: "completed",
      correlation_id: correlation_id,
      root_recording_id: root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user",
      initiator_snapshot: initiator_snapshot,
      total_tokens: 5,
      latency_ms: 20,
      created_at: Time.current
    )
  end
end
