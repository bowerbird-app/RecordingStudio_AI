# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260527000015)
class IsolateRecordingStudioApiClientAccessRecordings < ActiveRecord::Migration[8.1]
  class Access < ActiveRecord::Base
    self.table_name = "recording_studio_accesses"
  end

  class ApiClient < ActiveRecord::Base
    self.table_name = "recording_studio_api_api_clients"
  end

  class ApiCredential < ActiveRecord::Base
    self.table_name = "recording_studio_api_api_credentials"
  end

  class Recording < ActiveRecord::Base
    self.table_name = "recording_studio_recordings"
  end

  def up
    say_with_time "Isolating RecordingStudioApi::ApiClient access recordings" do
      ApiClient.find_each do |api_client|
        next if client_owned_access_recording?(api_client)

        source_access_recording = Recording.find_by(id: api_client.access_recording_id, recordable_type: "RecordingStudio::Access")
        next if source_access_recording.nil?

        source_access = Access.find_by(id: source_access_recording.recordable_id)
        next if source_access.nil?

        isolated_access = Access.create!(
          actor_type: "RecordingStudioApi::ApiClient",
          actor_id: api_client.id,
          role: source_access.role,
          created_at: api_client.created_at
        )

        isolated_access_recording = Recording.create!(
          recordable_type: "RecordingStudio::Access",
          recordable_id: isolated_access.id,
          parent_recording_id: source_access_recording.parent_recording_id,
          root_recording_id: source_access_recording.root_recording_id,
          trashed_at: source_access_recording.trashed_at,
          created_at: api_client.created_at,
          updated_at: api_client.updated_at
        )

        api_client_recordings = Recording.where(recordable_type: "RecordingStudioApi::ApiClient", recordable_id: api_client.id)
        if api_client_recordings.exists?
          api_client_recordings.update_all(parent_recording_id: isolated_access_recording.id, root_recording_id: isolated_access_recording.root_recording_id, updated_at: Time.current)
        else
          Recording.create!(
            recordable_type: "RecordingStudioApi::ApiClient",
            recordable_id: api_client.id,
            parent_recording_id: isolated_access_recording.id,
            root_recording_id: isolated_access_recording.root_recording_id,
            created_at: api_client.created_at,
            updated_at: api_client.updated_at
          )
        end

        ApiCredential.where(api_client_id: api_client.id)
                     .update_all(access_recording_id: isolated_access_recording.id, updated_at: Time.current)
        ApiClient.where(id: api_client.id)
                 .update_all(access_recording_id: isolated_access_recording.id, updated_at: Time.current)
      end
    end
  end

  def down
    # The old shared-access topology cannot be reconstructed safely once clients
    # have independent role changes, so this migration is intentionally one-way.
  end

  private

  def client_owned_access_recording?(api_client)
    Recording.joins("INNER JOIN #{Access.table_name} ON #{Access.table_name}.id = #{Recording.table_name}.recordable_id")
             .where(
               Recording.table_name => {
                 id: api_client.access_recording_id,
                 recordable_type: "RecordingStudio::Access"
               },
               Access.table_name => {
                 actor_type: "RecordingStudioApi::ApiClient",
                 actor_id: api_client.id
               }
             ).exists?
  end
end