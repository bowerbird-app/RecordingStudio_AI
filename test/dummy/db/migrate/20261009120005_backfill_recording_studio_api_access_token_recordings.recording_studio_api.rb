# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000005)
class BackfillRecordingStudioApiAccessTokenRecordings < ActiveRecord::Migration[8.1]
  class ApiAccessToken < ActiveRecord::Base
    self.table_name = "recording_studio_api_api_access_tokens"
  end

  class Recording < ActiveRecord::Base
    self.table_name = "recording_studio_recordings"
  end

  def up
    say_with_time "Backfilling RecordingStudioApi::ApiAccessToken recordings" do
      unresolved_count = 0

      ApiAccessToken.find_each do |token|
        next if token_recording_exists?(token)

        credential_recording = credential_recording_for(token)
        if credential_recording.nil?
          unresolved_count += 1
          next
        end

        Recording.create!(
          recordable_type: "RecordingStudioApi::ApiAccessToken",
          recordable_id: token.id,
          parent_recording_id: credential_recording.id,
          root_recording_id: credential_recording.root_recording_id,
          created_at: token.created_at,
          updated_at: token.updated_at
        )
      end

      raise ActiveRecord::MigrationError, "Unable to backfill #{unresolved_count} API access token recordings" if unresolved_count.positive?
    end
  end

  def down
    Recording.where(recordable_type: "RecordingStudioApi::ApiAccessToken").delete_all
  end

  private

  def token_recording_exists?(token)
    Recording.exists?(recordable_type: "RecordingStudioApi::ApiAccessToken", recordable_id: token.id)
  end

  def credential_recording_for(token)
    Recording.find_by(recordable_type: "RecordingStudioApi::ApiCredential", recordable_id: token.api_credential_id)
  end
end