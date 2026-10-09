# frozen_string_literal: true

require "test_helper"

class AIMetricsTest < ActiveSupport::TestCase
  GrantContext = Struct.new(:access_grant)
  Grant = Struct.new(:actor)

  setup do
    @staff = User.create!(
      email: "metrics-staff-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    @outsider = User.create!(
      email: "metrics-outsider-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    Current.actor = @staff
    @workspace = Workspace.create!(name: "Metrics #{SecureRandom.hex(4)}")
    @root = RecordingStudio.root_recording_for(@workspace)
    @admin_root = RecordingStudio.root_recording_for(Workspace.find_or_create_by!(name: "Admin"))
    AdminRoot.find_or_create_by!(name: "Admin")
    grant!(@admin_root, @staff, :admin)
    bootstrap_owner!(@root, @staff)
    @original_resolver = RecordingStudioAdmin.configuration.access_recording_resolver
    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) { @admin_root }
    seed_runs!
    Current.actor = nil
  end

  teardown do
    RecordingStudioAdmin.configuration.access_recording_resolver = @original_resolver
    Current.actor = nil
  end

  test "registered AI run metrics return seeded status, model, token, and latency values" do
    identifiers = RecordingStudioMetrics.definitions.map(&:identifier)
    %w[
      ai_runs.over_time
      ai_runs.by_status
      ai_runs.by_model
      ai_runs.tokens
      ai_runs.tokens_over_time
      ai_runs.avg_latency
    ].each { |identifier| assert_includes identifiers, identifier }

    status_counts = breakdown_counts(execute("ai_runs.by_status"))
    RecordingStudioAI::Run::STATUSES.values.each do |status|
      assert_equal RecordingStudioAI::Run.where(status: status).count, status_counts[status].to_i
    end

    model_counts = breakdown_counts(execute("ai_runs.by_model"))
    assert_equal RecordingStudioAI::Run.where(resolved_model: "gpt-test").count, model_counts["gpt-test"].to_i
    assert_equal RecordingStudioAI::Run.where(resolved_model: "gemini-test").count, model_counts["gemini-test"].to_i

    assert_equal RecordingStudioAI::Run.sum(:total_tokens), execute("ai_runs.tokens").value
    expected_latency = RecordingStudioAI::Run.average(:latency_ms)&.to_f
    assert_in_delta expected_latency, execute("ai_runs.avg_latency").value.to_f, 0.001

    opened = timeseries_counts(
      execute(
        "ai_runs.over_time",
        interval: "month",
        start_at: Time.utc(2026, 2, 1),
        end_at: Time.utc(2026, 4, 1)
      )
    )
    assert_equal runs_between(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)), opened["2026-02-01"]
    assert_equal runs_between(Time.utc(2026, 3, 1), Time.utc(2026, 4, 1)), opened["2026-03-01"]
    assert_operator opened["2026-02-01"], :>=, 1
    assert_operator opened["2026-03-01"], :>=, 2

    tokens = timeseries_counts(
      execute(
        "ai_runs.tokens_over_time",
        interval: "month",
        start_at: Time.utc(2026, 2, 1),
        end_at: Time.utc(2026, 4, 1)
      )
    )
    assert_equal tokens_between(Time.utc(2026, 2, 1), Time.utc(2026, 3, 1)), tokens["2026-02-01"]
    assert_equal tokens_between(Time.utc(2026, 3, 1), Time.utc(2026, 4, 1)), tokens["2026-03-01"]
  end

  test "api_authorize allows AdminRoot staff and denies non-admins" do
    authorize = RecordingStudioMetrics.registry.api_authorize_for(:ai_runs)
    assert_equal RecordingStudioAI::Metrics::AUTHORIZE, authorize

    assert authorize.call(GrantContext.new(Grant.new(@staff)))
    refute authorize.call(GrantContext.new(Grant.new(@outsider)))
    refute authorize.call(GrantContext.new(Grant.new(nil)))
  end

  private

  def execute(identifier, **params)
    RecordingStudioMetrics.execute(
      identifier,
      context: site_context,
      cache: false,
      **params
    )
  end

  def site_context
    RecordingStudioMetrics::Context.new(
      scope: :site,
      actor: @staff,
      site_authorized: true,
      timezone: "UTC"
    )
  end

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

  def runs_between(start_at, end_at)
    RecordingStudioAI::Run.where(created_at: start_at...end_at).count
  end

  def tokens_between(start_at, end_at)
    RecordingStudioAI::Run.where(created_at: start_at...end_at).sum(:total_tokens)
  end

  def breakdown_counts(result)
    result.data.to_h { |row| [(row[:key] || row["key"]).to_s, row[:value] || row["value"]] }
  end

  def timeseries_counts(result)
    result.data.to_h { |row| [(row[:date] || row["date"]).to_s, row[:value] || row["value"]] }
  end

  def bootstrap_owner!(recording, actor)
    result = RecordingStudioAccessible.bootstrap_owner_access!(
      recording: recording,
      actor: actor
    )
    raise result.error if result.failure?
  end

  def grant!(recording, actor, role)
    return if RecordingStudioAccessible.authorized?(actor: actor, recording: recording, role: role)

    original = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
    result = RecordingStudioAccessible.grant_access(
      recording: recording,
      actor: actor,
      role: role,
      manager_actor: @staff
    )
    raise result.error if result.failure?
  ensure
    RecordingStudioAccessible.configuration.access_management_authorizer = original
  end
end
