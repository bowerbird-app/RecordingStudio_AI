# frozen_string_literal: true

class RemovePromptNamespaceAndShortNameFromRecordingStudioAIRuns < ActiveRecord::Migration[8.1]
  def change
    remove_index :recording_studio_ai_runs, name: "idx_rsai_runs_prompt_created_at" \
      if index_exists?(:recording_studio_ai_runs, %i[prompt_namespace prompt_key prompt_version created_at],
                       name: "idx_rsai_runs_prompt_created_at")
    remove_column :recording_studio_ai_runs, :prompt_namespace, :string
    remove_column :recording_studio_ai_runs, :prompt_short_name_snapshot, :string
    add_index :recording_studio_ai_runs, %i[prompt_key prompt_version created_at],
              name: "idx_rsai_runs_prompt_created_at"
  end
end
