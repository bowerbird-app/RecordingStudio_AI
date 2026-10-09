# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260519000004)
class BackfillRecordingStudioApiCredentialRecordings < ActiveRecord::Migration[8.1]
  class ApiCredential < ActiveRecord::Base
    self.table_name = "recording_studio_api_api_credentials"
  end

  class Recording < ActiveRecord::Base
    self.table_name = "recording_studio_recordings"
  end

  def up
    say_with_time "Backfilling RecordingStudioApi::ApiCredential recordings" do
      ApiCredential.find_each do |credential|
        next if credential_recording_exists?(credential)

        parent_recording = api_client_recording_for(credential)
        next if parent_recording.nil?

        Recording.create!(
          recordable_type: "RecordingStudioApi::ApiCredential",
          recordable_id: credential.id,
          parent_recording_id: parent_recording.id,
          root_recording_id: parent_recording.root_recording_id,
          created_at: credential.created_at,
          updated_at: credential.updated_at
        )
      end

      orphan_count = ApiCredential.count { |credential| !credential_recording_exists?(credential) }
      raise ActiveRecord::MigrationError, "Unable to backfill #{orphan_count} API credential recordings" if orphan_count.positive?
    end
  end

  def down
    Recording.where(recordable_type: "RecordingStudioApi::ApiCredential").delete_all
  end

  private

  def credential_recording_exists?(credential)
    Recording.exists?(recordable_type: "RecordingStudioApi::ApiCredential", recordable_id: credential.id)
  end

  def api_client_recording_for(credential)
    Recording.find_by(recordable_type: "RecordingStudioApi::ApiClient", recordable_id: credential.api_client_id)
  end
end
