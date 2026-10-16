# frozen_string_literal: true

class AllowRecordingStudioAIHostedAgentRuns < ActiveRecord::Migration[8.1]
  RUNS = :recording_studio_ai_runs
  CONSTRAINT = "chk_rsai_runs_operation"
  OPERATIONS = "operation IN ('generation','stream','batch','decision','tool','hosted_agent')"
  PREVIOUS = "operation IN ('generation','stream','batch','decision','tool')"

  def up
    add_column RUNS, :provider_session_id, :string
    add_column RUNS, :provider_turn_id, :string
    add_index RUNS, :provider_session_id
    add_index RUNS, :provider_turn_id
    replace_constraint(RUNS, CONSTRAINT, OPERATIONS)
  end

  def down
    if hosted_agent_rows?
      raise ActiveRecord::IrreversibleMigration,
            "hosted_agent runs still exist; apply the host retention policy first"
    end

    remove_index RUNS, :provider_turn_id
    remove_index RUNS, :provider_session_id
    remove_column_preserving_triggers(RUNS, :provider_turn_id)
    remove_column_preserving_triggers(RUNS, :provider_session_id)
    replace_constraint(RUNS, CONSTRAINT, PREVIOUS)
  end

  private

  def replace_constraint(table, name, expression)
    triggers = sqlite_trigger_definitions(table)
    remove_check_constraint table, name: name, if_exists: true
    add_check_constraint table, expression, name: name
    triggers.each { |definition| execute definition }
  end

  def remove_column_preserving_triggers(table, column)
    triggers = sqlite_trigger_definitions(table)
    remove_column table, column
    triggers.each { |definition| execute definition }
  end

  def sqlite_trigger_definitions(table)
    return [] unless connection.adapter_name.match?(/SQLite/i)

    connection.select_values(
      "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = #{connection.quote(table.to_s)}"
    ).compact
  end

  def hosted_agent_rows?
    connection.select_value(
      "SELECT COUNT(*) FROM recording_studio_ai_runs WHERE operation = 'hosted_agent'"
    ).to_i.positive?
  end
end
