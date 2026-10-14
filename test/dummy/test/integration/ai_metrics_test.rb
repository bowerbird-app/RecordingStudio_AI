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

  test "failed runs over time group by stored error_category with from, to and list filters" do
    travel_to Time.utc(2026, 5, 4, 12) do
      6.times { create_run!(status: "failed", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1, error_category: "rate_limit") }
      create_run!(status: "failed", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1, error_category: "timeout")
      create_run!(status: "completed", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1)
    end
    travel_to Time.utc(2026, 5, 5, 12) do
      create_run!(status: "failed", resolved_model: "gemini-test", total_tokens: 1, latency_ms: 1, error_category: "rate_limit")
    end

    result = execute(
      "ai_runs.failed_over_time",
      interval: "day",
      start_at: Time.utc(2026, 5, 4),
      end_at: Time.utc(2026, 5, 6),
      group_by: "error_category"
    )
    assert_equal "count", result.unit
    totals = timeseries_counts(result)
    assert_equal({ "2026-05-04" => 7, "2026-05-05" => 1 }, totals)
    assert_equal "error_category", result.group_by.to_s
    keys = result.groups.map { |row| (row[:key] || row["key"]).to_s }
    assert_equal %w[rate_limit], keys
    totals.each do |date, total|
      grouped = result.groups.sum { |row| series_value(row[:data] || row["data"], date) }
      grouped += series_value(result.other[:data] || result.other["data"], date) if result.other
      assert_equal total, grouped
    end

    filtered = timeseries_counts(
      execute(
        "ai_runs.failed_over_time",
        interval: "day",
        start_at: Time.utc(2026, 5, 4),
        end_at: Time.utc(2026, 5, 6),
        filters: { model: "gemini-test" }
      )
    )
    assert_equal({ "2026-05-04" => 0, "2026-05-05" => 1 }, filtered)
  end

  test "stuck runs use config.stuck_run_threshold and report the oldest age in seconds" do
    now = Time.utc(2026, 6, 1, 12)
    original = RecordingStudioAI.configuration.stuck_run_threshold
    RecordingStudioAI.configuration.stuck_run_threshold = 15.minutes
    travel_to(now - 2.hours) { create_run!(status: "running", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1, started_at: now - 90.minutes) }
    travel_to(now - 20.minutes) { create_run!(status: "pending", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1) }
    travel_to(now - 5.minutes) { create_run!(status: "running", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1, started_at: now - 5.minutes) }
    travel_to(now - 3.hours) { create_run!(status: "completed", resolved_model: "gpt-test", total_tokens: 1, latency_ms: 1) }

    travel_to now do
      assert_equal 2, execute("ai_runs.stuck").value
      assert_equal 90.minutes.to_i, execute("ai_runs.oldest_stuck_age").value
      assert_equal 1, execute("ai_runs.stuck", filters: { status: "pending" }).value
      assert_equal "seconds", execute("ai_runs.oldest_stuck_age").unit

      RecordingStudioAI.configuration.stuck_run_threshold = 1.hour
      assert_equal 1, execute("ai_runs.stuck").value
      RecordingStudioAI.configuration.stuck_run_threshold = 3.hours
      assert_equal 0, execute("ai_runs.stuck").value
      assert_nil execute("ai_runs.oldest_stuck_age").value
    end
  ensure
    RecordingStudioAI.configuration.stuck_run_threshold = original
  end

  test "failure and stuck metrics expose catalog fields and refuse identifying group_by" do
    catalog = RecordingStudioMetrics.definitions.index_by(&:identifier)
    failed = catalog.fetch("ai_runs.failed_over_time")
    stuck = catalog.fetch("ai_runs.stuck")
    oldest = catalog.fetch("ai_runs.oldest_stuck_age")

    assert_equal [:error_category], failed.group_by
    assert_equal %i[status operation], stuck.group_by
    assert_equal [], oldest.group_by
    assert_equal "Failed AI runs", failed.title
    assert_equal "seconds", oldest.unit
    [failed, stuck, oldest].each do |definition|
      assert definition.description.present?
      assert_equal :site, definition.blast_radius
      filter_names = definition.filters.map(&:name)
      assert_equal %i[operation prompt prompt_version provider model], filter_names.first(5)
    end
    assert_equal :status, stuck.filters.last.name

    %w[initiator_id root_recording_id request_id error_message].each do |field|
      assert_raises(RecordingStudioMetrics::Errors::InvalidGroupBy) do
        execute("ai_runs.failed_over_time", interval: "day", group_by: field)
      end
    end
  end

  test "tokens by profile sums tokens per profile_key and honors list filters" do
    RecordingStudioAI::Run.delete_all
    create_run!(status: "completed", resolved_model: "m1", total_tokens: 100, latency_ms: 10).update_columns(profile_key: "summary")
    create_run!(status: "completed", resolved_model: "m2", total_tokens: 50, latency_ms: 10).update_columns(profile_key: "summary")
    create_run!(status: "failed", resolved_model: "m1", total_tokens: 7, latency_ms: 10).update_columns(profile_key: "draft")

    counts = breakdown_counts(execute("ai_runs.tokens_by_profile"))
    assert_equal 150, counts["summary"].to_i
    assert_equal 7, counts["draft"].to_i
    assert_equal 100, breakdown_counts(execute("ai_runs.tokens_by_profile", filters: { model: "m1" }))["summary"].to_i
  end

  test "fallback retry rate is the share of runs with a retry or fallback per period" do
    RecordingStudioAI::Run.delete_all
    travel_to Time.utc(2026, 10, 8, 12) do
      create_run!(status: "completed", resolved_model: "m1", total_tokens: 1, latency_ms: 1).update_columns(retry_count: 1)
      create_run!(status: "completed", resolved_model: "m1", total_tokens: 1, latency_ms: 1).update_columns(fallback_count: 2)
      create_run!(status: "completed", resolved_model: "m1", total_tokens: 1, latency_ms: 1)
      create_run!(status: "completed", resolved_model: "m2", total_tokens: 1, latency_ms: 1)
    end
    window = { interval: "day", start_at: Time.utc(2026, 10, 7), end_at: Time.utc(2026, 10, 10) }

    rates = timeseries_counts(execute("ai_runs.fallback_retry_rate", **window))
    assert_in_delta 0.5, rates["2026-10-08"].to_f, 0.0001
    assert_in_delta 2.0 / 3, timeseries_counts(
      execute("ai_runs.fallback_retry_rate", **window, filters: { model: "m1" })
    )["2026-10-08"].to_f, 0.0001
  end

  test "ai batches by status counts batches per status" do
    RecordingStudioAI::Batch.delete_all
    %w[completed completed failed].each do |status|
      RecordingStudioAI::Batch.create!(
        status: status, root_recording_id: @root.id, initiator_type: "User", initiator_id: @staff.id,
        initiator_kind: "user"
      )
    end
    counts = breakdown_counts(execute("ai_batches.by_status"))
    assert_equal 2, counts["completed"].to_i
    assert_equal 1, counts["failed"].to_i
  end

  test "new AI metrics carry unit, title and description" do
    {
      "ai_runs.tokens_by_profile" => "tokens",
      "ai_runs.fallback_retry_rate" => "ratio",
      "ai_batches.by_status" => "count"
    }.each do |identifier, unit|
      metadata = RecordingStudioMetrics.find(identifier).catalog_metadata
      assert_equal unit, metadata[:unit], identifier
      assert metadata[:title].present?, identifier
      assert metadata[:description].present?, identifier
      assert_equal [:operations], metadata[:exposed_apis], identifier
    end
    assert_equal true, RecordingStudioMetrics.find("ai_runs.fallback_retry_rate").catalog_metadata.dig(:date_range, :supported)
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

  def create_run!(status:, resolved_model:, total_tokens:, latency_ms:, error_category: nil, started_at: nil)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      error_category: error_category,
      started_at: started_at,
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

  def series_value(data, date)
    row = data.find { |entry| (entry[:date] || entry["date"]).to_s == date }
    row ? (row[:value] || row["value"]) : 0
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
