# frozen_string_literal: true

class AddPromptAttributionToRecordingStudioAIRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :recording_studio_ai_runs, :prompt_namespace, :string
    add_column :recording_studio_ai_runs, :prompt_key, :string
    add_column :recording_studio_ai_runs, :prompt_version, :integer
    add_column :recording_studio_ai_runs, :prompt_name_snapshot, :string
    add_column :recording_studio_ai_runs, :prompt_short_name_snapshot, :string

    add_index :recording_studio_ai_runs, %i[prompt_namespace prompt_key prompt_version created_at],
              name: "idx_rsai_runs_prompt_created_at"
  end
end