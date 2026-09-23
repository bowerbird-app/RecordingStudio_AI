# frozen_string_literal: true

class AllowRecordingStudioAIDecisionExecutions < ActiveRecord::Migration[8.1]
  RUNS_CONSTRAINT = "chk_rsai_runs_operation"
  RESPONSES_CONSTRAINT = "chk_rsai_responses_type"

  def up
    replace_constraint(:recording_studio_ai_runs, RUNS_CONSTRAINT,
                       "operation IN ('generation','stream','batch','decision')")
    replace_constraint(:recording_studio_ai_responses, RESPONSES_CONSTRAINT,
                       "response_type IN ('generation','stream','batch_item','error','decision')")
  end

  def down
    if decision_rows?
      raise ActiveRecord::IrreversibleMigration,
            "decision runs or retained decision responses still exist; apply the host retention policy first"
    end

    replace_constraint(:recording_studio_ai_responses, RESPONSES_CONSTRAINT,
                       "response_type IN ('generation','stream','batch_item','error')")
    replace_constraint(:recording_studio_ai_runs, RUNS_CONSTRAINT,
                       "operation IN ('generation','stream','batch')")
  end

  private

  def replace_constraint(table, name, expression)
    triggers = sqlite_trigger_definitions(table)
    remove_check_constraint table, name: name, if_exists: true
    add_check_constraint table, expression, name: name
    triggers.each { |definition| execute definition }
  end

  # SQLite cannot alter a check constraint, so Rails rewrites the table and the
  # history integrity triggers attached to it are dropped with the old copy.
  def sqlite_trigger_definitions(table)
    return [] unless connection.adapter_name.match?(/SQLite/i)

    connection.select_values(
      "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = #{connection.quote(table.to_s)}"
    ).compact
  end

  def decision_rows?
    count_of("recording_studio_ai_runs", "operation").positive? ||
      count_of("recording_studio_ai_responses", "response_type").positive?
  end

  def count_of(table, column)
    connection.select_value("SELECT COUNT(*) FROM #{table} WHERE #{column} = 'decision'").to_i
  end
end
