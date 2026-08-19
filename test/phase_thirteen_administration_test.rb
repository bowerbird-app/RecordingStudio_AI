# frozen_string_literal: true

require "test_helper"
require "recording_studio_ai/admin/recording_studio_ai_widgets"

class PhaseThirteenAdministrationTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Data.define(:id)

  def setup
    super
    @configuration = isolate_configuration!
    @configuration.attribution_validator = ->(**) {}
    @actor = Actor.new(id: 42)
    install_recording_lookup_double
  end

  def build_recording_lookup(id)
    @find_count = (@find_count || 0) + 1 if instance_variable_defined?(:@find_count)
    Actor.new(id:)
  end

  def test_admin_access_fails_closed_without_host_resolvers
    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioAI::Admin::Access.new(controller: Object.new, configuration: @configuration)
    end
  end

  def test_admin_access_authorizes_each_visible_root_and_keeps_sensitive_permission_separate
    root_ids = [create_recording_id, create_recording_id]
    calls = []
    @find_count = 0
    @configuration.admin_actor_resolver = ->(controller:) { @actor }
    @configuration.admin_visible_roots_resolver = ->(actor:, controller:) { root_ids }
    @configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << [action, attribution.root_recording.id, context]
      action != "recording_studio_ai.view_sensitive_execution"
    end

    access = RecordingStudioAI::Admin::Access.new(controller: Object.new, configuration: @configuration)

    assert_equal root_ids, access.root_ids
    assert_equal(2, calls.count { |action, _, _| action == "recording_studio_ai.view_execution" })
    assert_equal 2, @find_count
    refute access.allowed?(:view_sensitive_execution, root_id: root_ids.first, context: { record_id: 1 })
    assert_equal "recording_studio_ai.view_sensitive_execution", calls.last.first
    assert_equal 2, @find_count, "sensitive checks must reuse cached root recordings"
  end

  def test_weekly_calls_series_aggregates_in_sql_without_loading_all_runs
    root_id = create_recording_id
    this_week = Time.current.beginning_of_week
    last_week = this_week - 1.week
    create_run(root_id: root_id, status: "completed", tokens: 5, created_at: this_week + 1.hour)
    create_run(root_id: root_id, status: "completed", tokens: 7, created_at: this_week + 2.hours)
    create_run(root_id: root_id, status: "completed", tokens: 3, created_at: last_week + 1.day)

    series = AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
      RecordingStudioAI::Run.where(root_recording_id: root_id),
      weeks_back: 2,
      series_name: "AI calls"
    )
    token_series = AdminScreens::RecordingStudioAIWidgets.weekly_token_series(
      RecordingStudioAI::Run.where(root_recording_id: root_id),
      weeks_back: 2,
      series_name: "Token usage"
    )

    assert_equal 2, series.first.fetch(:data).length
    assert_equal 2, series.first.fetch(:data).last.fetch(:y)
    assert_equal 1, series.first.fetch(:data).first.fetch(:y)
    assert_equal 12, token_series.first.fetch(:data).last.fetch(:y)
    assert_equal 3, token_series.first.fetch(:data).first.fetch(:y)
  end

  def test_top_prompt_call_rows_resolve_names_without_per_prompt_lookups
    root_id = create_recording_id
    create_run(
      root_id: root_id, status: "completed", tokens: 1,
      prompt_namespace: "docs", prompt_key: "summarize", prompt_name_snapshot: "Summarize page"
    )
    create_run(
      root_id: root_id, status: "completed", tokens: 1,
      prompt_namespace: "docs", prompt_key: "summarize", prompt_name_snapshot: "Summarize page"
    )
    create_run(
      root_id: root_id, status: "completed", tokens: 1,
      prompt_namespace: "docs", prompt_key: "outline", prompt_name_snapshot: "Outline"
    )

    rows = AdminScreens::RecordingStudioAIWidgets.top_prompt_call_rows(
      RecordingStudioAI::Run.where(root_recording_id: root_id),
      range: 1.day.ago..Time.current,
      limit: 5
    )

    assert_equal ["Summarize page", "docs", "summarize", 2], rows.first
    assert_equal ["Outline", "docs", "outline", 1], rows.last
  end

  def test_widget_memo_dedupes_repeated_chart_row_lookups
    root_id = create_recording_id
    create_run(root_id: root_id, status: "completed", tokens: 10, resolved_model: "gpt-test")
    context = Object.new
    context.define_singleton_method(:root_recording) { Actor.new(id: root_id) }
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!

    first = AdminScreens::RecordingStudioAIWidgets.top_model_call_volume_rows(context)
    second = AdminScreens::RecordingStudioAIWidgets.top_model_call_volume_rows(context)

    assert_equal first, second
    assert_equal [["gpt-test", 1]], first
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_warning_metrics_are_restricted_to_visible_roots
    visible_root = create_recording_id
    hidden_root = create_recording_id
    create_run(root_id: visible_root, status: "completed", tokens: 10)
    create_run(root_id: hidden_root, status: "failed", tokens: 90)

    result = RecordingStudioAI::WarningMetrics.new(
      since: 1.hour.ago,
      root_ids: [visible_root],
      thresholds: { error_rate: 0.5, total_tokens: 50 }
    ).call

    assert_equal 0.0, result[:values][:error_rate]
    assert_equal 10, result[:values][:total_tokens]
    assert_empty result[:breaches]
  end

  def test_warning_metrics_fail_closed_without_root_ids
    create_run(root_id: create_recording_id, status: "failed", tokens: 90)

    result = RecordingStudioAI::WarningMetrics.new(
      since: 1.hour.ago,
      thresholds: { runs: 1, error_rate: 0.1 }
    ).call

    assert_equal 0, result[:values][:runs]
    assert_nil result[:values][:error_rate]
    assert_empty result[:breaches]
  end

  def test_admin_runs_scope_fails_closed_without_a_root
    visible_root = create_recording_id
    create_run(root_id: visible_root, status: "completed", tokens: 10)
    context = Struct.new(:root_recording).new(nil)

    assert_empty AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_admin_screens_and_filters_stay_inside_the_current_root
    visible_root = create_recording_id
    hidden_root = create_recording_id
    visible_run = create_run(
      root_id: visible_root, status: "completed", tokens: 10,
      prompt_key: "visible-prompt", resolved_provider: "openai", resolved_model: "gpt-visible"
    )
    hidden_run = create_run(
      root_id: hidden_root, status: "failed", tokens: 90,
      prompt_key: "hidden-prompt", resolved_provider: "gemini", resolved_model: "gemini-hidden"
    )
    visible_attempt = visible_run.attempts.create!(
      sequence: 1, kind: "primary", status: "completed", provider: "openai", model: "gpt-visible"
    )
    hidden_attempt = hidden_run.attempts.create!(
      sequence: 1, kind: "primary", status: "failed", provider: "gemini", model: "gemini-hidden"
    )
    visible_run.custom_tool_invocations.create!(
      tool_key: "visible-tool", tool_version: 1, status: "completed", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true
    )
    hidden_run.custom_tool_invocations.create!(
      tool_key: "hidden-tool", tool_version: 1, status: "completed", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true
    )
    RecordingStudioAI::Response.create!(
      attempt: visible_attempt, response_type: "generation", provider: "openai", model: "gpt-visible",
      complete: true, byte_size: 12
    )
    RecordingStudioAI::Response.create!(
      attempt: hidden_attempt, response_type: "error", provider: "gemini", model: "gemini-hidden",
      complete: false, byte_size: 34
    )

    context = Struct.new(:root_recording).new(Actor.new(id: visible_root))
    widgets = AdminScreens::RecordingStudioAIWidgets

    assert_equal [visible_run.id], widgets.runs_scope(context).pluck(:id)
    assert_equal [visible_attempt.id], widgets.attempts_scope(context).pluck(:id)
    assert_equal ["visible-tool"], widgets.tool_scope(context).pluck(:tool_key)
    assert_equal ["openai"], widgets.responses_scope(context).pluck(:provider)
    assert_equal %w[completed], widgets.run_distinct_values(:status)
    assert_equal %w[visible-prompt], widgets.run_present_distinct_values(:prompt_key)
    assert_equal %w[openai], widgets.run_distinct_values(:resolved_provider)
    assert_equal %w[gpt-visible], widgets.run_distinct_values(:resolved_model)
    assert_equal %w[visible-tool], widgets.tool_distinct_values(:tool_key)
    assert_equal %w[openai], widgets.response_distinct_values(:provider)
    refute_includes widgets.run_present_distinct_values(:prompt_key), "hidden-prompt"
    refute_includes widgets.tool_distinct_values(:tool_key), "hidden-tool"
    refute_includes widgets.response_distinct_values(:provider), "gemini"
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_warning_metrics_leave_mixed_currency_spend_unknown
    root_id = create_recording_id
    create_run(root_id: root_id, status: "completed", tokens: 10)
    create_run(root_id: root_id, status: "completed", tokens: 10)

    result = RecordingStudioAI::WarningMetrics.new(
      since: 1.hour.ago, root_ids: [root_id], thresholds: { spend_microunits: 1 }
    ).call

    assert_nil result[:values][:spend_microunits]
    assert_empty result[:breaches]
  end

  def test_warning_metrics_include_run_expensive_model_and_calls_per_run_thresholds
    root_id = create_recording_id
    run = create_run(root_id: root_id, status: "completed", tokens: 10)
    run.update_column(:resolved_model, "premium-model")
    2.times do |index|
      run.custom_tool_invocations.create!(
        tool_key: "tool-#{index}", tool_version: 1, status: "completed", read_only: true,
        destructive: false, requires_confirmation: false, idempotent: true
      )
    end
    @configuration.admin_expensive_models = ["premium-model"]

    result = RecordingStudioAI::WarningMetrics.new(
      since: 1.hour.ago, root_ids: [root_id],
      thresholds: { runs: 1, expensive_model_runs: 1, maximum_tool_calls_per_run: 2 }
    ).call

    assert_equal 1, result[:values][:runs]
    assert_equal 1, result[:values][:expensive_model_runs]
    assert_equal 2, result[:values][:maximum_tool_calls_per_run]
    assert_equal %i[runs maximum_tool_calls_per_run expensive_model_runs].sort,
                 result[:breaches].pluck(:metric).sort
  end

  def test_admin_routes_are_read_only
    load RecordingStudioAI::Engine.root.join("config/routes.rb")

    verbs = RecordingStudioAI::Engine.routes.routes.map(&:verb).compact.uniq
    assert_equal ["GET"], verbs
    refute(RecordingStudioAI::Engine.routes.routes.any? do |route|
      route.defaults[:action].match?(/create|update|destroy|replay|cancel|refresh/)
    end)
  end

  def test_attempt_error_code_column_is_visible_only_for_failed_status
    widgets = AdminScreens::RecordingStudioAIWidgets
    failed_context = Object.new
    def failed_context.filter_value(key) = key.to_sym == :status ? "failed" : nil
    def failed_context.params = {}

    completed_context = Object.new
    def completed_context.filter_value(key) = key.to_sym == :status ? "completed" : nil
    def completed_context.params = {}

    assert widgets.attempt_error_code_column_visible?(failed_context)
    refute widgets.attempt_error_code_column_visible?(completed_context)
    refute widgets.attempt_error_code_column_visible?(nil)
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_latency_prompt_rows_include_a_calls_series_for_the_selected_range
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    create_run(
      root_id: root_id,
      status: "completed",
      tokens: 10,
      prompt_key: "latency-series",
      prompt_name_snapshot: "Latency series",
      latency_ms: 120
    )
    date_range = 3.days.ago.beginning_of_day..Time.current

    rows = AdminScreens::RecordingStudioAIWidgets.latency_rows_for_runs(
      AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where.not(latency_ms: nil),
      dimension: :prompt,
      date_range: date_range
    )
    row = rows.find { |entry| entry.prompt_key == "latency-series" }

    assert row
    assert_equal 4, row.calls_series.length
    series_total = row.calls_series.sum { |point| point[:y] }
    assert_equal row.calls, series_total
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_latency_model_rows_include_a_calls_series_for_the_selected_range
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    create_run(
      root_id: root_id,
      status: "completed",
      tokens: 10,
      resolved_model: "latency-series-model",
      latency_ms: 80,
      created_at: 2.days.ago
    )
    create_run(
      root_id: root_id,
      status: "completed",
      tokens: 10,
      resolved_model: "latency-series-model",
      latency_ms: 90,
      created_at: 10.days.ago
    )
    date_range = 3.days.ago.beginning_of_day..Time.current

    runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
                                                 .where(created_at: date_range)
                                                 .where.not(latency_ms: nil)
    rows = AdminScreens::RecordingStudioAIWidgets.latency_rows_for_runs(
      runs,
      dimension: :model,
      date_range: date_range
    )
    row = rows.find { |entry| entry.resolved_model == "latency-series-model" }

    assert row
    assert_equal 1, row.calls
    assert_equal 4, row.calls_series.length
    series_total = row.calls_series.sum { |point| point[:y] }
    assert_equal 1, series_total
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_date_range_query_keeps_custom_dates_when_a_preset_does_not_match
    start_date = 3.days.ago.to_date
    end_date = Date.current
    range = Struct.new(:start_date, :end_date, :preset_key).new(start_date, end_date, :last_4_weeks)
    context = Struct.new(:selected_range, :params).new(range, {})
    def context.filter_value(_key) = selected_range

    query = AdminScreens::RecordingStudioAIWidgets.date_range_query(context, screen: nil)

    assert_equal start_date.iso8601, query[:start_date]
    assert_equal end_date.iso8601, query[:end_date]
    refute query.key?(:date_range_preset)
  end

  def test_prompt_call_count_uses_the_selected_range_not_definition_count
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    widgets = AdminScreens::RecordingStudioAIWidgets
    current = Struct.new(:start_date, :end_date, :preset_key).new(Date.current - 27, Date.current, :last_4_weeks)
    previous = widgets.previous_period_date_range(current)

    create_run(
      root_id: root_id, status: "completed", tokens: 4, prompt_key: "current-prompt",
      created_at: current.end_date.beginning_of_day + 1.hour
    )
    create_run(
      root_id: root_id, status: "completed", tokens: 4, prompt_key: "previous-prompt",
      created_at: previous.end_date.beginning_of_day + 1.hour
    )
    create_run(
      root_id: root_id, status: "completed", tokens: 4, prompt_key: "older-prompt",
      created_at: previous.start_date.beginning_of_day - 2.days
    )

    assert_equal 1, widgets.prompt_call_count(context, date_range: current)
    assert_equal 1, widgets.prompt_call_count(context, date_range: previous)
    assert_equal current.start_date - 28.days, previous.start_date
    assert_equal 0, widgets.prompt_call_count(context, date_range: nil)
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_latency_p90_for_range_uses_selected_runs_not_row_count
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    widgets = AdminScreens::RecordingStudioAIWidgets
    current = Struct.new(:start_date, :end_date, :preset_key).new(Date.current - 27, Date.current, :last_4_weeks)
    previous = widgets.previous_period_date_range(current)

    [100, 200, 300, 400, 500, 600, 700, 800, 900, 10_000].each do |latency_ms|
      create_run(
        root_id: root_id, status: "completed", tokens: 4, latency_ms: latency_ms,
        resolved_model: "p90-model", created_at: current.end_date.beginning_of_day + 1.hour
      )
    end
    10.times do
      create_run(
        root_id: root_id, status: "completed", tokens: 4, latency_ms: 100,
        resolved_model: "p90-model", created_at: previous.end_date.beginning_of_day + 1.hour
      )
    end

    assert_equal 900, widgets.latency_p90_for_range(context, date_range: current)
    assert_equal 100, widgets.latency_p90_for_range(context, date_range: previous)
    assert_equal 0, widgets.latency_p90_for_range(context, date_range: nil)
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_filter_model_rows_by_provider_keeps_matching_rows
    widgets = AdminScreens::RecordingStudioAIWidgets
    openai = Struct.new(:provider).new("openai")
    gemini = Struct.new(:provider).new("gemini")
    context = Object.new
    def context.filter_value(key) = key.to_sym == :provider ? "openai" : nil

    assert_equal [openai], widgets.filter_model_rows_by_provider([openai, gemini], context)
    assert_equal [openai, gemini], widgets.filter_model_rows_by_provider([openai, gemini], Object.new)
  end

  def test_attempt_kind_label_uses_everyday_words
    widgets = AdminScreens::RecordingStudioAIWidgets

    assert_equal "1st attempt", widgets.attempt_kind_label("primary")
    assert_equal "After tools", widgets.attempt_kind_label("continuation")
    assert_equal "Retry", widgets.attempt_kind_label("retry")
  end

  def test_model_token_totals_ranks_every_model
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    widgets = AdminScreens::RecordingStudioAIWidgets
    create_run(root_id: root_id, status: "completed", tokens: 10, resolved_model: "small-model", total_tokens: 100)
    create_run(root_id: root_id, status: "completed", tokens: 20, resolved_model: "big-model", total_tokens: 400)
    create_run(root_id: root_id, status: "completed", tokens: 5, resolved_model: "small-model", total_tokens: 50)

    create_run(root_id: root_id, status: "completed", tokens: 8, resolved_model: nil, total_tokens: 75)
    current = Struct.new(:start_date, :end_date, :preset_key).new(Date.current, Date.current, nil)
    totals = widgets.model_token_totals(widgets.runs_scope(context))

    assert_equal [["big-model", 400], ["small-model", 150], ["Unknown", 75]], totals
    assert_equal 625, widgets.token_total_for_range(context, date_range: current)
    assert_equal 0, widgets.token_total_for_range(context, date_range: nil)
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_model_call_totals_ranks_every_model
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    widgets = AdminScreens::RecordingStudioAIWidgets
    create_run(root_id: root_id, status: "completed", tokens: 10, resolved_model: "small-model")
    create_run(root_id: root_id, status: "completed", tokens: 20, resolved_model: "big-model")
    create_run(root_id: root_id, status: "completed", tokens: 5, resolved_model: "small-model")
    create_run(root_id: root_id, status: "completed", tokens: 8, resolved_model: nil)

    totals = widgets.model_call_totals(widgets.runs_scope(context))

    assert_equal [["small-model", 2], ["big-model", 1], ["Unknown", 1]], totals
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  def test_call_volume_totals_can_group_by_provider
    root_id = create_recording_id
    context = Struct.new(:root_recording).new(Actor.new(id: root_id))
    widgets = AdminScreens::RecordingStudioAIWidgets
    create_run(root_id: root_id, status: "completed", tokens: 10, resolved_provider: "openai", resolved_model: "a")
    create_run(root_id: root_id, status: "completed", tokens: 20, resolved_provider: "openai", resolved_model: "b")
    create_run(root_id: root_id, status: "completed", tokens: 5, resolved_provider: "google", resolved_model: "c")

    totals = widgets.call_volume_totals(widgets.runs_scope(context), group_by: :provider)

    assert_equal [["openai", 2], ["google", 1]], totals

    model_context = Object.new
    def model_context.filter_value(_key) = nil
    provider_context = Object.new
    def provider_context.filter_value(_key) = "provider"

    assert_equal :model, widgets.call_volume_group_by(model_context)
    assert_equal :provider, widgets.call_volume_group_by(provider_context)
  ensure
    AdminScreens::RecordingStudioAIWidgets.clear_admin_context!
  end

  private

  def create_run(root_id:, status:, tokens:, **attributes)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      root_recording_id: root_id,
      initiator_type: "User",
      initiator_id: @actor.id,
      initiator_kind: "user",
      total_tokens: tokens,
      created_at: Time.current,
      **attributes
    )
  end
end
