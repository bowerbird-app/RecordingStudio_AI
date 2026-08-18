# frozen_string_literal: true

require "test_helper"

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
    @configuration.admin_actor_resolver = ->(controller:) { @actor }
    @configuration.admin_visible_roots_resolver = ->(actor:, controller:) { root_ids }
    @configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << [action, attribution.root_recording.id, context]
      action != "recording_studio_ai.view_sensitive_execution"
    end

    access = RecordingStudioAI::Admin::Access.new(controller: Object.new, configuration: @configuration)

    assert_equal root_ids, access.root_ids
    assert_equal(2, calls.count { |action, _, _| action == "recording_studio_ai.view_execution" })
    refute access.allowed?(:view_sensitive_execution, root_id: root_ids.first, context: { record_id: 1 })
    assert_equal "recording_studio_ai.view_sensitive_execution", calls.last.first
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

  private

  def create_run(root_id:, status:, tokens:)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      root_recording_id: root_id,
      initiator_type: "User",
      initiator_id: @actor.id,
      initiator_kind: "user",
      total_tokens: tokens,
      created_at: Time.current
    )
  end
end
