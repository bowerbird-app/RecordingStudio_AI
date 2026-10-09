# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260525000012)
class CreateRecordingStudioApiApiRequestLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_api_request_logs, id: :uuid do |t|
      t.datetime :occurred_at, null: false
      t.string :request_id
      t.string :request_method, null: false
      t.string :request_path, null: false
      t.string :route_name
      t.string :controller_name
      t.string :action_name
      t.integer :status_code, null: false
      t.integer :duration_ms, null: false
      t.boolean :rate_limited, null: false, default: false
      t.uuid :api_client_id
      t.uuid :api_credential_id
      t.uuid :access_recording_id
      t.uuid :scope_recording_id
      t.uuid :root_recording_id
      t.uuid :oauth_grant_session_id
      t.string :remote_ip
      t.string :user_agent
      t.string :error_class
      t.string :error_message
      t.jsonb :request_params, null: false, default: {}

      t.timestamps
    end

    add_index :recording_studio_api_api_request_logs, :occurred_at
    add_index :recording_studio_api_api_request_logs, :request_id
    add_index :recording_studio_api_api_request_logs, :status_code
    add_index :recording_studio_api_api_request_logs, :request_path
    add_index :recording_studio_api_api_request_logs,
              %i[api_client_id occurred_at],
              name: "index_rs_api_request_logs_on_client_and_time"
    add_index :recording_studio_api_api_request_logs,
              %i[api_credential_id occurred_at],
              name: "index_rs_api_request_logs_on_credential_and_time"
  end
end
