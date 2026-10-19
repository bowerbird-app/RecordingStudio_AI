# frozen_string_literal: true

class AddRecordingStudioAIHostedTurns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  TABLE = :recording_studio_ai_hosted_turns
  RUNS = :recording_studio_ai_runs
  RESPONSE_INDEX = "idx_rsai_hosted_turns_response_id"
  SESSION_INDEX = "idx_rsai_hosted_turns_session"
  RUNNING_INDEX = "idx_rsai_runs_one_running_hosted_session"
  RUNNING_WHERE = "operation = 'hosted_agent' AND status = 'running' AND provider_session_id IS NOT NULL"

  def up
    create_hosted_turns
    add_running_session_index
    assert_running_index_valid!
  end

  def down
    remove_running_session_index
    drop_table TABLE, if_exists: true
  end

  private

  def create_hosted_turns
    create_table TABLE, if_not_exists: true do |table|
      table.string :provider_session_id, null: false
      table.string :response_id, null: false
      table.integer :sequence_number
      table.boolean :text_emitted, null: false, default: false
      table.timestamps
    end
    add_index TABLE, :response_id, unique: true, if_not_exists: true, name: RESPONSE_INDEX
    add_index TABLE, :provider_session_id, if_not_exists: true, name: SESSION_INDEX
  end

  def add_running_session_index
    return if index_name_exists?(RUNS, RUNNING_INDEX)

    options = { unique: true, where: RUNNING_WHERE, name: RUNNING_INDEX, if_not_exists: true }
    options[:algorithm] = :concurrently if postgres?
    add_index RUNS, :provider_session_id, **options
  end

  def remove_running_session_index
    return unless index_name_exists?(RUNS, RUNNING_INDEX)

    options = { name: RUNNING_INDEX, if_exists: true }
    options[:algorithm] = :concurrently if postgres?
    remove_index RUNS, **options
  end

  def assert_running_index_valid!
    return unless postgres?

    valid = select_value(<<~SQL.squish)
      SELECT i.indisvalid
      FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      WHERE c.relname = #{connection.quote(RUNNING_INDEX)}
    SQL
    return if valid == true || valid.to_s == "t"

    raise "Index #{RUNNING_INDEX} is not valid. Drop the invalid index and rerun this migration."
  end

  def postgres?
    connection.adapter_name.match?(/postgre/i)
  end
end
