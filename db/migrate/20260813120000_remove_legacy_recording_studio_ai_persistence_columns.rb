# frozen_string_literal: true

class RemoveLegacyRecordingStudioAIPersistenceColumns < ActiveRecord::Migration[8.1]
  def change
    remove_columns :recording_studio_ai_runs,
                   :initiator_snapshot,
                   :executor_snapshot,
                   :impersonator_snapshot,
                   :input_digest,
                   :output_digest
    remove_columns :recording_studio_ai_custom_tool_invocations,
                   :arguments_digest,
                   :arguments_summary,
                   :result_digest
    remove_columns :recording_studio_ai_batches,
                   :initiator_snapshot,
                   :executor_snapshot,
                   :impersonator_snapshot
  end
end