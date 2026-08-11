# frozen_string_literal: true

require "test_helper"
require "active_record"
require "securerandom"

migration_file = Dir[File.expand_path("../db/migrate/*_create_recording_studio_ai_persistence_tables.rb", __dir__)].first
require migration_file
require_relative "../app/models/recording_studio_ai/application_record"
require_relative "../app/models/concerns/recording_studio_ai/terminal_immutability"
require_relative "../app/models/recording_studio_ai/run"
require_relative "../app/models/recording_studio_ai/attempt"
require_relative "../app/models/recording_studio_ai/custom_tool_invocation"
require_relative "../app/models/recording_studio_ai/batch"
require_relative "../app/models/recording_studio_ai/batch_item"
require_relative "../app/models/recording_studio_ai/response"

class PhaseThirteenAdministrationTest < Minitest::Test
  Actor = Data.define(:id)

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.connection.create_table(:recording_studio_recordings) { |table| table.timestamps }
    ActiveRecord::Migration.suppress_messages { CreateRecordingStudioAIPersistenceTables.migrate(:up) }
    @configuration = RecordingStudioAI::Configuration.new
    @configuration.attribution_validator = ->(**) {}
    @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    RecordingStudioAI.instance_variable_set(:@configuration, @configuration)
    @actor = Actor.new(id: 42)
    install_recording_lookup_double
  end

  def teardown
    RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
    RecordingStudio.send(:remove_const, :Recording) if @remove_recording_lookup_double
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
    assert_equal 2, calls.count { |action, _, _| action == "recording_studio_ai.view_execution" }
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
    create_run(root_id: root_id, status: "completed", tokens: 10, cost: 100, currency: "USD")
    create_run(root_id: root_id, status: "completed", tokens: 10, cost: 200, currency: "EUR")

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
    refute RecordingStudioAI::Engine.routes.routes.any? { |route| route.defaults[:action].match?(/create|update|destroy|replay|cancel|refresh/) }
  end

  private

  def install_recording_lookup_double
    return if RecordingStudio.const_defined?(:Recording, false)

    actor_class = Actor
    RecordingStudio.const_set(:Recording, Class.new do
      define_singleton_method(:find) { |id| actor_class.new(id:) }
    end)
    @remove_recording_lookup_double = true
  end

  def create_recording_id
    ActiveRecord::Base.connection.insert(
      "INSERT INTO recording_studio_recordings (created_at, updated_at) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
  end

  def create_run(root_id:, status:, tokens:, cost: nil, currency: nil)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      correlation_id: SecureRandom.uuid,
      root_recording_id: root_id,
      initiator_type: "User",
      initiator_id: @actor.id,
      initiator_kind: "user",
      total_tokens: tokens,
      cost_amount_microunits: cost,
      cost_currency: currency,
      created_at: Time.current
    )
  end
end
