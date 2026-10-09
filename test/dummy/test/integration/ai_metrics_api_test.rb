# frozen_string_literal: true

require "test_helper"

class AIMetricsApiTest < ActionDispatch::IntegrationTest
  OPERATIONS_ROOT = "/recording_studio_api/apis/operations/v1"
  PUBLIC_ROOT = "/recording_studio_api/api/v1"

  setup do
    @staff = User.create!(
      email: "metrics-staff-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    @patron = User.create!(
      email: "metrics-patron-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    Current.actor = @staff
    @workspace = Workspace.create!(name: "Metrics #{SecureRandom.hex(4)}")
    @root = RecordingStudio.root_recording_for(@workspace)
    @admin_root = RecordingStudio.root_recording_for(AdminRoot.find_or_create_by!(name: "Admin"))
    grant_accessible!(recording: @admin_root, actor: @staff, role: :admin)
    grant_accessible!(recording: @root, actor: @staff, role: :admin)
    grant_accessible!(recording: @root, actor: @patron, role: :edit)

    seed_runs!

    @staff_operations_token = provision_token(
      access_point: @admin_root,
      actor: @staff,
      role: :admin,
      name: "Staff operations metrics #{SecureRandom.hex(4)}",
      api: :operations
    )
    @workspace_operations_token = provision_token(
      access_point: @root,
      actor: @staff,
      role: :edit,
      name: "Workspace operations metrics #{SecureRandom.hex(4)}",
      api: :operations
    )
    @public_token = provision_token(
      access_point: @root,
      actor: @staff,
      role: :view,
      name: "Public metrics #{SecureRandom.hex(4)}"
    )
    Current.actor = nil
  end

  teardown do
    Current.actor = nil
  end

  test "operations staff token reads AI run metrics" do
    get "#{OPERATIONS_ROOT}/metrics/ai_runs/by_status",
        headers: auth(@staff_operations_token),
        as: :json
    assert_response :success
    status_counts = breakdown_counts(response.parsed_body)
    RecordingStudioAI::Run::STATUSES.values.each do |status|
      assert_equal RecordingStudioAI::Run.where(status: status).count, status_counts[status].to_i
    end

    get "#{OPERATIONS_ROOT}/metrics/ai_runs/by_model",
        headers: auth(@staff_operations_token),
        as: :json
    assert_response :success
    model_counts = breakdown_counts(response.parsed_body)
    assert_equal RecordingStudioAI::Run.where(resolved_model: "gpt-test").count, model_counts["gpt-test"].to_i
    assert_equal RecordingStudioAI::Run.where(resolved_model: "gemini-test").count, model_counts["gemini-test"].to_i

    get "#{OPERATIONS_ROOT}/metrics/ai_runs/tokens",
        headers: auth(@staff_operations_token),
        as: :json
    assert_response :success
    assert_equal RecordingStudioAI::Run.sum(:total_tokens), response.parsed_body.fetch("value")

    get "#{OPERATIONS_ROOT}/metrics/ai_runs/avg_latency",
        headers: auth(@staff_operations_token),
        as: :json
    assert_response :success
    expected_latency = RecordingStudioAI::Run.average(:latency_ms)&.to_f
    assert_in_delta expected_latency, response.parsed_body.fetch("value").to_f, 0.001

    get "#{OPERATIONS_ROOT}/metrics/ai_runs/over_time",
        params: { interval: "month" },
        headers: auth(@staff_operations_token),
        as: :json
    assert_response :success
    opened = timeseries_counts(response.parsed_body)
    assert_equal runs_between(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)), opened["2026-02-01"]
    assert_equal runs_between(Time.utc(2026, 3, 1), Time.utc(2026, 4, 1)), opened["2026-03-01"]
    assert_operator opened["2026-02-01"], :>=, 1
    assert_operator opened["2026-03-01"], :>=, 2

    get "#{OPERATIONS_ROOT}/metrics/ai_runs/tokens_over_time",
        params: { interval: "month" },
        headers: auth(@staff_operations_token),
        as: :json
    assert_response :success
    tokens = timeseries_counts(response.parsed_body)
    assert_equal tokens_between(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)), tokens["2026-02-01"]
    assert_equal tokens_between(Time.utc(2026, 3, 1), Time.utc(2026, 4, 1)), tokens["2026-03-01"]
  end

  test "metrics index lists AI run metrics" do
    get "#{OPERATIONS_ROOT}/metrics", headers: auth(@staff_operations_token), as: :json

    assert_response :success
    identifiers = response.parsed_body.fetch("metrics").map { |row| row.fetch("identifier") }
    %w[
      ai_runs.over_time
      ai_runs.by_status
      ai_runs.by_model
      ai_runs.tokens
      ai_runs.tokens_over_time
      ai_runs.avg_latency
    ].each { |identifier| assert_includes identifiers, identifier }
  end

  test "non-admin operations token is denied AI metrics" do
    get "#{OPERATIONS_ROOT}/metrics/ai_runs/tokens",
        headers: auth(@workspace_operations_token),
        as: :json
    assert_response :forbidden

    get "#{OPERATIONS_ROOT}/metrics", headers: auth(@workspace_operations_token), as: :json
    assert_response :success
    identifiers = response.parsed_body.fetch("metrics").map { |row| row.fetch("identifier") }
    refute_includes identifiers, "ai_runs.tokens"
  end

  test "public API token is denied operations AI metrics" do
    get "#{OPERATIONS_ROOT}/metrics/ai_runs/tokens",
        headers: auth(@public_token),
        as: :json
    assert_response :unauthorized

    get "#{PUBLIC_ROOT}/metrics/ai_runs/tokens",
        headers: auth(@public_token),
        as: :json
    assert_includes [404, 401, 403], response.status
  end

  private

  def seed_runs!
    travel_to Time.utc(2026, 2, 10, 12) do
      create_run!(status: "completed", resolved_model: "gpt-test", total_tokens: 100, latency_ms: 200)
    end
    travel_to Time.utc(2026, 3, 12, 12) do
      create_run!(status: "failed", resolved_model: "gemini-test", total_tokens: 40, latency_ms: 400)
      create_run!(status: "cancelled", resolved_model: "gpt-test", total_tokens: 10, latency_ms: 50)
    end
  end

  def create_run!(status:, resolved_model:, total_tokens:, latency_ms:)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      resolved_model: resolved_model,
      resolved_provider: "test",
      latency_ms: latency_ms,
      total_tokens: total_tokens,
      root_recording_id: @root.id,
      context_recording_id: @root.id,
      initiator_type: "User",
      initiator_id: @staff.id,
      initiator_kind: "user"
    )
  end

  def breakdown_counts(payload)
    payload.fetch("data").to_h { |row| [row.fetch("key").to_s, row.fetch("value")] }
  end

  def runs_between(start_at, end_at)
    RecordingStudioAI::Run.where(created_at: start_at...end_at).count
  end

  def tokens_between(start_at, end_at)
    RecordingStudioAI::Run.where(created_at: start_at...end_at).sum(:total_tokens)
  end

  def timeseries_counts(payload)
    payload.fetch("data").to_h { |row| [row.fetch("date").to_s, row.fetch("value")] }
  end

  def auth(token)
    { "Authorization" => "Bearer #{token}", "Accept" => "application/json" }
  end

  def provision_token(access_point:, actor:, role:, name:, api: :public)
    original = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
    result = RecordingStudioApi::Services::ProvisionApiClient.call(
      access_point_recording: access_point,
      manager_actor: actor,
      role: role,
      name: name,
      api: api
    )
    raise result.error unless result.success?

    payload = result.value
    token_result = RecordingStudioApi::Services::IssueOauthAccessToken.call(
      grant_type: "client_credentials",
      client_id: payload.fetch(:credential).oauth_client_id,
      client_secret: payload.fetch(:token),
      api: api
    )
    raise token_result.error unless token_result.success?

    token_result.value.fetch(:access_token)
  ensure
    RecordingStudioAccessible.configuration.access_management_authorizer = original
  end
end
