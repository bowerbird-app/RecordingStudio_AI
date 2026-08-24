# frozen_string_literal: true

class RemoveCorrelationIdsFromRecordingStudioAI < ActiveRecord::Migration[8.1]
  def change
    remove_index :recording_studio_ai_runs, :correlation_id, if_exists: true
    remove_column :recording_studio_ai_runs, :correlation_id, :string, if_exists: true

    remove_index :recording_studio_ai_batches, :correlation_id, if_exists: true
    remove_column :recording_studio_ai_batches, :correlation_id, :string, if_exists: true
  end
end