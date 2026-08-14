# frozen_string_literal: true

require "test_helper"
require "active_record"
require "securerandom"

Dir[File.expand_path("../db/migrate/*.rb", __dir__)].sort.each { |migration_file| require migration_file }

require_relative "../app/models/recording_studio_ai/application_record"
require_relative "../app/models/concerns/recording_studio_ai/terminal_immutability"
require_relative "../app/models/recording_studio_ai/run"
require_relative "../app/models/recording_studio_ai/attempt"
require_relative "../app/models/recording_studio_ai/custom_tool_invocation"
require_relative "../app/models/recording_studio_ai/batch"
require_relative "../app/models/recording_studio_ai/batch_item"
require_relative "../app/models/recording_studio_ai/response"

class PhaseThreePersistenceTest < Minitest::Test
  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    bootstrap_external_recording_studio_table

    ActiveRecord::Migration.suppress_messages do
      CreateRecordingStudioAIPersistenceTables.migrate(:up)
      HardenRecordingStudioAIPersistence.migrate(:up)
      EnforceRecordingStudioAIHistoryIntegrity.migrate(:up)
    end
  end

  def teardown
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end

  def test_phase_three_creates_exactly_six_infrastructure_tables
    tables = ActiveRecord::Base.connection.tables

    expected = %w[
      recording_studio_ai_runs
      recording_studio_ai_attempts
      recording_studio_ai_custom_tool_invocations
      recording_studio_ai_batches
      recording_studio_ai_batch_items
      recording_studio_ai_responses
    ]

    assert_equal expected.sort, (tables & expected).sort
  end

  def test_required_indexes_exist_for_runs_attempts_batches_and_batch_items
    connection = ActiveRecord::Base.connection

    run_indexes = connection.indexes(:recording_studio_ai_runs)
    attempt_indexes = connection.indexes(:recording_studio_ai_attempts)
    assert(attempt_indexes.any? { |index| index.columns == %w[run_id sequence] && index.unique })

    batch_indexes = connection.indexes(:recording_studio_ai_batches)
    batch_item_indexes = connection.indexes(:recording_studio_ai_batch_items)
    assert(batch_item_indexes.any? { |index| index.columns == ["run_id"] && index.unique })
    assert(batch_item_indexes.any? { |index| index.columns == %w[batch_id position] && index.unique })
    assert(batch_item_indexes.any? { |index| index.columns == %w[batch_id reference] && index.unique })
  end

  def test_response_table_has_xor_and_type_constraints
    connection = ActiveRecord::Base.connection

    expressions = if connection.respond_to?(:check_constraints)
                    connection.check_constraints(:recording_studio_ai_responses).map(&:expression)
                  else
                    []
                  end

    if expressions.empty?
      sql = connection.select_value(<<~SQL.squish)
        SELECT sql FROM sqlite_master
        WHERE type = 'table' AND name = 'recording_studio_ai_responses'
      SQL

      assert_includes sql, "attempt_id IS NOT NULL"
      assert_includes sql, "batch_item_id IS NULL"
      assert_includes sql, "response_type IN"
      assert_includes sql, "generation"
      return
    end

    assert(expressions.any? do |expr|
      expr.include?("attempt_id IS NOT NULL") && expr.include?("batch_item_id IS NULL")
    end)
    assert(expressions.any? { |expr| expr.include?("response_type IN") && expr.include?("generation") })
  end

  def test_non_persistence_boundary_excludes_prompt_and_message_columns
    forbidden_columns = %w[prompt prompts message messages input_text output_text request_payload]
    connection = ActiveRecord::Base.connection

    %i[
      recording_studio_ai_runs
      recording_studio_ai_attempts
      recording_studio_ai_custom_tool_invocations
      recording_studio_ai_batches
      recording_studio_ai_batch_items
      recording_studio_ai_responses
    ].each do |table|
      column_names = connection.columns(table).map(&:name)
      forbidden_columns.each do |forbidden|
        refute_includes column_names, forbidden, "#{table} should not contain #{forbidden}"
      end
    end
  end

  def test_polymorphic_actor_identifiers_support_uuid_and_integer_hosts
    connection = ActiveRecord::Base.connection
    run_columns = connection.columns(:recording_studio_ai_runs).index_by(&:name)
    tool_columns = connection.columns(:recording_studio_ai_custom_tool_invocations).index_by(&:name)
    batch_columns = connection.columns(:recording_studio_ai_batches).index_by(&:name)

    assert_equal :string, run_columns.fetch("initiator_id").type
    assert_equal :string, run_columns.fetch("executor_id").type
    assert_equal :string, run_columns.fetch("impersonator_id").type
    assert_equal :string, tool_columns.fetch("confirmed_by_id").type
    assert_equal :string, batch_columns.fetch("initiator_id").type
    assert_equal :string, batch_columns.fetch("executor_id").type
    assert_equal :string, batch_columns.fetch("impersonator_id").type
  end

  def test_database_rejects_invalid_operations_timelines_sources_and_tool_categories
    root_recording_id = create_recording_id
    run = RecordingStudioAI::Run.create!(
      operation: "generation", status: "pending", root_recording_id: root_recording_id,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )

    assert_raises(ActiveRecord::StatementInvalid) { run.update_column(:operation, "conversation") }
    assert_raises(ActiveRecord::StatementInvalid) do
      run.update_columns(started_at: Time.current, completed_at: 1.minute.ago)
    end

    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "pending")
    refute ActiveRecord::Base.connection.column_exists?(:recording_studio_ai_attempts, :cost_source)

    invocation = run.custom_tool_invocations.create!(
      tool_key: "lookup", tool_version: 1, status: "requested", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true
    )
    refute ActiveRecord::Base.connection.column_exists?(:recording_studio_ai_custom_tool_invocations, :cost_category)
    assert_raises(ActiveRecord::StatementInvalid) { invocation.update_column(:confirmation_status, "approved_later") }
  end

  def test_run_terminal_status_blocks_mutating_terminal_fields
    root_recording_id = create_recording_id

    run = RecordingStudioAI::Run.create!(
      operation: "generation",
      status: "pending",
      profile_key: "medium",
      root_recording_id: root_recording_id,
      initiator_type: "User",
      initiator_id: 1,
      initiator_kind: "user"
    )

    assert run.update(status: "completed")
    refute run.update(resolved_provider: "openai")
    assert_includes run.errors.full_messages.join, "Cannot modify terminal fields"
    assert_raises(ActiveRecord::StatementInvalid) { run.update_column(:resolved_provider, "gemini") }
  end

  def test_all_terminal_execution_models_block_ordinary_terminal_field_mutations
    root_recording_id = create_recording_id
    run = RecordingStudioAI::Run.create!(
      operation: "generation", status: "completed", root_recording_id: root_recording_id,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed")
    invocation = run.custom_tool_invocations.create!(
      tool_key: "lookup", tool_version: 1, status: "completed", read_only: true,
      destructive: false, requires_confirmation: false, idempotent: true
    )
    batch = RecordingStudioAI::Batch.create!(
      status: "completed", root_recording_id: root_recording_id,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user",
      item_count: 1, completed_item_count: 1
    )
    item = batch.batch_items.create!(run: run, position: 0, reference: "item-1", status: "completed")

    {
      attempt => { provider_request_id: "provider-request" },
      invocation => { result_summary: "changed" },
      batch => { provider_batch_id: "provider-batch" },
      item => { provider_item_id: "provider-item" }
    }.each do |record, attributes|
      refute record.update(attributes), record.class.name
      assert_includes record.errors.full_messages.join, "Cannot modify terminal fields"
    end
  end

  def test_invocation_links_and_batch_items_cannot_cross_execution_boundaries
    first_root = create_recording_id
    second_root = create_recording_id
    first_run = RecordingStudioAI::Run.create!(
      operation: "generation", status: "pending", root_recording_id: first_root,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    second_run = RecordingStudioAI::Run.create!(
      operation: "batch", status: "pending", root_recording_id: second_root,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    first_attempt = first_run.attempts.create!(sequence: 1, kind: "primary", status: "pending")
    invocation = second_run.custom_tool_invocations.new(
      requested_by_attempt: first_attempt, tool_key: "lookup", tool_version: 1, status: "requested",
      read_only: true, destructive: false, requires_confirmation: false, idempotent: true
    )
    refute invocation.valid?
    assert_includes invocation.errors[:requested_by_attempt_id], "must belong to the same run"

    batch = RecordingStudioAI::Batch.create!(
      status: "preparing", root_recording_id: first_root,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    item = batch.batch_items.new(run: second_run, position: 0, reference: "cross-root", status: "pending")
    refute item.valid?
    assert_includes item.errors[:run_id], "must belong to the batch root"

    assert_raises(ActiveRecord::StatementInvalid) do
      RecordingStudioAI::BatchItem.insert_all!([{
        batch_id: batch.id, run_id: second_run.id, position: 0, reference: "direct-cross-root",
        status: "pending", created_at: Time.current, updated_at: Time.current
      }])
    end
    assert_raises(ActiveRecord::StatementInvalid) { first_attempt.update_column(:run_id, second_run.id) }
    assert_raises(ActiveRecord::StatementInvalid) { first_run.update_column(:root_recording_id, second_root) }
    assert_raises(ActiveRecord::StatementInvalid) { batch.update_column(:root_recording_id, second_root) }
  end

  def test_attempt_deletion_cannot_nullify_custom_tool_history
    root_recording_id = create_recording_id
    run = RecordingStudioAI::Run.create!(
      operation: "generation", status: "pending", root_recording_id: root_recording_id,
      initiator_type: "User", initiator_id: "user-1", initiator_kind: "user"
    )
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "pending")
    run.custom_tool_invocations.create!(
      requested_by_attempt: attempt, tool_key: "lookup", tool_version: 1, status: "requested",
      read_only: true, destructive: false, requires_confirmation: false, idempotent: true
    )

    assert_raises(ActiveRecord::DeleteRestrictionError) { attempt.destroy! }
  end

  def test_retained_response_model_enforces_xor_and_declares_encrypted_fields
    response = RecordingStudioAI::Response.new(response_type: "generation")

    assert_equal false, response.valid?
    assert_includes response.errors.full_messages.join, "exactly one of attempt_id or batch_item_id"

    encrypted_attributes = RecordingStudioAI::Response.encrypted_attributes.map(&:to_s)
    assert_includes encrypted_attributes, "raw_response"
    assert_includes encrypted_attributes, "normalized_response"
    assert_includes encrypted_attributes, "content_text"
  end

  private

  def bootstrap_external_recording_studio_table
    ActiveRecord::Base.connection.create_table(:recording_studio_recordings) do |t|
      t.timestamps
    end
  end

  def create_recording_id
    ActiveRecord::Base.connection.insert("INSERT INTO recording_studio_recordings (created_at, updated_at) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)")
  end
end
