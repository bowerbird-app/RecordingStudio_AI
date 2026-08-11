# frozen_string_literal: true

class HardenRecordingStudioAIPersistence < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_ai_batches, :impersonator_type, :string
    add_column :recording_studio_ai_batches, :impersonator_id, :string
    add_column :recording_studio_ai_batches, :impersonator_snapshot, :json
    add_index :recording_studio_ai_batches, %i[impersonator_type impersonator_id]

    add_check_constraint :recording_studio_ai_runs,
                         "operation IN ('generation','stream','batch')",
                         name: "chk_rsai_runs_operation"
    add_check_constraint :recording_studio_ai_runs,
                         "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at",
                         name: "chk_rsai_runs_timeline"
    add_check_constraint :recording_studio_ai_attempts,
                         "cost_source IS NULL OR cost_source IN ('provider','catalog','estimate','unavailable')",
                         name: "chk_rsai_attempts_cost_source"
    add_check_constraint :recording_studio_ai_attempts,
                         "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at",
                         name: "chk_rsai_attempts_timeline"
    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "cost_category IS NULL OR cost_category IN ('negligible','low','medium','high')",
                         name: "chk_rsai_tool_invocations_cost_category"
    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "latency_category IS NULL OR latency_category IN ('instant','fast','slow')",
                         name: "chk_rsai_tool_invocations_latency_category"
    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "confirmation_status IS NULL OR confirmation_status IN ('not_required','pending','confirmed','rejected','expired')",
                         name: "chk_rsai_tool_invocations_confirmation_status"
    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "(confirmation_status = 'confirmed' AND confirmed_by_type IS NOT NULL AND confirmed_by_id IS NOT NULL AND confirmed_at IS NOT NULL) OR " \
                         "(confirmation_status != 'confirmed' AND confirmed_by_type IS NULL AND confirmed_by_id IS NULL AND confirmed_at IS NULL) OR " \
                         "confirmation_status IS NULL",
                         name: "chk_rsai_tool_invocations_confirmer"
    add_check_constraint :recording_studio_ai_custom_tool_invocations,
                         "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at",
                         name: "chk_rsai_tool_invocations_timeline"
    add_check_constraint :recording_studio_ai_batches,
                         "completed_at IS NULL OR submitted_at IS NULL OR completed_at >= submitted_at",
                         name: "chk_rsai_batches_timeline"
    add_check_constraint :recording_studio_ai_batch_items,
                         "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at",
                         name: "chk_rsai_batch_items_timeline"

    execute <<~SQL.squish
      UPDATE recording_studio_ai_responses
      SET expires_at = created_at
      WHERE expires_at IS NULL
    SQL
    change_column_null :recording_studio_ai_responses, :expires_at, false
  end

  def down
    change_column_null :recording_studio_ai_responses, :expires_at, true

    remove_check_constraint :recording_studio_ai_batch_items, name: "chk_rsai_batch_items_timeline"
    remove_check_constraint :recording_studio_ai_batches, name: "chk_rsai_batches_timeline"
    remove_check_constraint :recording_studio_ai_custom_tool_invocations, name: "chk_rsai_tool_invocations_timeline"
    remove_check_constraint :recording_studio_ai_custom_tool_invocations, name: "chk_rsai_tool_invocations_confirmer"
    remove_check_constraint :recording_studio_ai_custom_tool_invocations,
                            name: "chk_rsai_tool_invocations_confirmation_status"
    remove_check_constraint :recording_studio_ai_custom_tool_invocations,
                            name: "chk_rsai_tool_invocations_latency_category"
    remove_check_constraint :recording_studio_ai_custom_tool_invocations,
                            name: "chk_rsai_tool_invocations_cost_category"
    remove_check_constraint :recording_studio_ai_attempts, name: "chk_rsai_attempts_timeline"
    remove_check_constraint :recording_studio_ai_attempts, name: "chk_rsai_attempts_cost_source"
    remove_check_constraint :recording_studio_ai_runs, name: "chk_rsai_runs_timeline"
    remove_check_constraint :recording_studio_ai_runs, name: "chk_rsai_runs_operation"

    remove_index :recording_studio_ai_batches, %i[impersonator_type impersonator_id]
    remove_column :recording_studio_ai_batches, :impersonator_snapshot
    remove_column :recording_studio_ai_batches, :impersonator_id
    remove_column :recording_studio_ai_batches, :impersonator_type
  end
end
