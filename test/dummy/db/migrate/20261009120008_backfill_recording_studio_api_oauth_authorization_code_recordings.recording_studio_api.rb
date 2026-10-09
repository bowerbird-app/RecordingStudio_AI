# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000008)
class BackfillRecordingStudioApiOauthAuthorizationCodeRecordings < ActiveRecord::Migration[8.1]
  class OauthAuthorizationCode < ActiveRecord::Base
    self.table_name = "recording_studio_api_oauth_authorization_codes"
  end

  class Recording < ActiveRecord::Base
    self.table_name = "recording_studio_recordings"
  end

  def up
    say_with_time "Backfilling RecordingStudioApi::OauthAuthorizationCode recordings" do
      unresolved_count = 0

      OauthAuthorizationCode.find_each do |authorization_code|
        next if authorization_code_recording_exists?(authorization_code)

        access_recording = access_recording_for(authorization_code)
        if access_recording.nil?
          unresolved_count += 1
          next
        end

        Recording.create!(
          recordable_type: "RecordingStudioApi::OauthAuthorizationCode",
          recordable_id: authorization_code.id,
          parent_recording_id: access_recording.id,
          root_recording_id: access_recording.root_recording_id,
          created_at: authorization_code.created_at,
          updated_at: authorization_code.updated_at
        )
      end

      if unresolved_count.positive?
        raise ActiveRecord::MigrationError,
              "Unable to backfill #{unresolved_count} OAuth authorization code recordings"
      end
    end
  end

  def down
    Recording.where(recordable_type: "RecordingStudioApi::OauthAuthorizationCode").delete_all
  end

  private

  def authorization_code_recording_exists?(authorization_code)
    Recording.exists?(recordable_type: "RecordingStudioApi::OauthAuthorizationCode", recordable_id: authorization_code.id)
  end

  def access_recording_for(authorization_code)
    Recording.find_by(id: authorization_code.access_recording_id, recordable_type: "RecordingStudio::Access")
  end
end