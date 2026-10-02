# frozen_string_literal: true

class AllowRecordingStudioAIToolExecutions < ActiveRecord::Migration[8.1]
  RUNS_CONSTRAINT = "chk_rsai_runs_operation"
  INVOCATIONS = :recording_studio_ai_custom_tool_invocations

  def up
    replace_constraint(:recording_studio_ai_runs, RUNS_CONSTRAINT,
                       "operation IN ('generation','stream','batch','decision','tool')")
    add_column INVOCATIONS, :arguments, :json
    add_column INVOCATIONS, :result, :json
  end

  def down
    if tool_rows?
      raise ActiveRecord::IrreversibleMigration,
            "tool runs still exist; apply the host retention policy first"
    end

    remove_column_preserving_triggers(INVOCATIONS, :result)
    remove_column_preserving_triggers(INVOCATIONS, :arguments)
    replace_constraint(:recording_studio_ai_runs, RUNS_CONSTRAINT,
                       "operation IN ('generation','stream','batch','decision')")
  end

  private

  def replace_constraint(table, name, expression)
    triggers = sqlite_trigger_definitions(table)
    remove_check_constraint table, name: name, if_exists: true
    add_check_constraint table, expression, name: name
    triggers.each { |definition| execute definition }
  end

  # SQLite rewrites a table to drop a column and drops the triggers attached to it.
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

  def tool_rows?
    connection.select_value(
      "SELECT COUNT(*) FROM recording_studio_ai_runs WHERE operation = 'tool'"
    ).to_i.positive?
  end
end
