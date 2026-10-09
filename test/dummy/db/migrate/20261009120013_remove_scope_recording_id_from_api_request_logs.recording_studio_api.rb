# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260526000013)
class RemoveScopeRecordingIdFromApiRequestLogs < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:recording_studio_api_api_request_logs)
    return unless column_exists?(:recording_studio_api_api_request_logs, :scope_recording_id)

    remove_column :recording_studio_api_api_request_logs, :scope_recording_id, :uuid
  end
end
