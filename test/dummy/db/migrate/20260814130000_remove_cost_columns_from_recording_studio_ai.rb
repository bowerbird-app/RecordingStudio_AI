# frozen_string_literal: true

class RemoveCostColumnsFromRecordingStudioAI < ActiveRecord::Migration[8.1]
  COST_COLUMNS = {
    recording_studio_ai_runs: %i[cost_amount_microunits cost_currency cost_estimated],
    recording_studio_ai_attempts: %i[cost_amount_microunits cost_currency cost_estimated cost_source],
    recording_studio_ai_custom_tool_invocations: %i[cost_category],
    recording_studio_ai_batches: %i[cost_amount_microunits cost_currency cost_estimated],
    recording_studio_ai_batch_items: %i[cost_amount_microunits cost_currency cost_estimated]
  }.freeze

  def change
    remove_check_constraint :recording_studio_ai_attempts, name: "chk_rsai_attempts_cost_source" \
      if check_constraint_exists?(:recording_studio_ai_attempts, name: "chk_rsai_attempts_cost_source")
    remove_check_constraint :recording_studio_ai_custom_tool_invocations,
                            name: "chk_rsai_tool_invocations_cost_category" \
      if check_constraint_exists?(:recording_studio_ai_custom_tool_invocations,
                                  name: "chk_rsai_tool_invocations_cost_category")
    COST_COLUMNS.each do |table, columns|
      remove_columns table, *columns
    end
  end
end