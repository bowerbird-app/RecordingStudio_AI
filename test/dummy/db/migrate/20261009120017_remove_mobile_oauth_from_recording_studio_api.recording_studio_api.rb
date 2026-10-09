# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260609000015)
class RemoveMobileOauthFromRecordingStudioApi < ActiveRecord::Migration[8.1]
  MOBILE_RECORDABLE_TYPES = %w[
    RecordingStudioApi::OauthAuthorizationCode
    RecordingStudioApi::OauthGrantSession
    RecordingStudioApi::OauthSessionAccessToken
    RecordingStudioApi::OauthRefreshToken
  ].freeze

  def up
    if table_exists?(:recording_studio_api_api_request_logs) &&
       column_exists?(:recording_studio_api_api_request_logs, :oauth_grant_session_id)
      remove_column :recording_studio_api_api_request_logs, :oauth_grant_session_id, :uuid
    end

    if table_exists?(:recording_studio_recordings)
      if table_exists?(:recording_studio_events)
        execute <<~SQL
          WITH RECURSIVE mobile_recordings AS (
            SELECT id FROM recording_studio_recordings
            WHERE recordable_type IN (#{quoted_mobile_recordable_types})

            UNION

            SELECT child.id FROM recording_studio_recordings child
            INNER JOIN mobile_recordings parent
              ON child.parent_recording_id = parent.id
              OR child.root_recording_id = parent.id
          )
          DELETE FROM recording_studio_events
          WHERE recording_id IN (SELECT id FROM mobile_recordings)
        SQL
      end

      execute <<~SQL
        WITH RECURSIVE mobile_recordings AS (
          SELECT id FROM recording_studio_recordings
          WHERE recordable_type IN (#{quoted_mobile_recordable_types})

          UNION

          SELECT child.id FROM recording_studio_recordings child
          INNER JOIN mobile_recordings parent
            ON child.parent_recording_id = parent.id
            OR child.root_recording_id = parent.id
        )
        DELETE FROM recording_studio_recordings
        WHERE id IN (SELECT id FROM mobile_recordings)
      SQL
    end

    drop_table :recording_studio_api_oauth_refresh_tokens, if_exists: true
    drop_table :recording_studio_api_oauth_session_access_tokens, if_exists: true
    drop_table :recording_studio_api_oauth_grant_sessions, if_exists: true
    drop_table :recording_studio_api_oauth_authorization_codes, if_exists: true
    drop_table :recording_studio_api_oauth_clients, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Mobile OAuth has been removed from RecordingStudioApi"
  end

  private

  def quoted_mobile_recordable_types
    MOBILE_RECORDABLE_TYPES.map { |value| quote(value) }.join(", ")
  end
end