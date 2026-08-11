# frozen_string_literal: true

class RestoreRecordingStudioAccessibleTables < ActiveRecord::Migration[8.1]
  def up
    create_table :recording_studio_accesses, id: :uuid, if_not_exists: true do |t|
      t.string :actor_type, null: false
      t.uuid :actor_id, null: false
      t.integer :role, null: false, default: 0
      t.datetime :created_at, null: false
    end

    create_table :recording_studio_access_boundaries, id: :uuid, if_not_exists: true do |t|
      t.integer :minimum_role
      t.datetime :created_at, null: false
    end

    add_index :recording_studio_accesses,
              %i[actor_type actor_id],
              name: "index_recording_studio_accesses_on_actor",
              if_not_exists: true

    add_index :recording_studio_accesses,
              %i[actor_type actor_id role],
              name: "index_recording_studio_accesses_on_actor_and_role",
              if_not_exists: true

    return unless supports_partial_indexes?

    add_index :recording_studio_recordings,
              %i[recordable_id root_recording_id],
              name: "idx_rs_recordings_root_access",
              where: "recordable_type = 'RecordingStudio::Access' AND parent_recording_id IS NOT NULL AND trashed_at IS NULL",
              if_not_exists: true

    add_index :recording_studio_recordings,
              :parent_recording_id,
              unique: true,
              name: "index_rs_unique_active_access_boundary_per_parent",
              where: "recordable_type = 'RecordingStudio::AccessBoundary' AND trashed_at IS NULL",
              if_not_exists: true
  end

  def down
    remove_index :recording_studio_recordings,
                 name: "index_rs_unique_active_access_boundary_per_parent",
                 if_exists: true
    remove_index :recording_studio_recordings,
                 name: "idx_rs_recordings_root_access",
                 if_exists: true
    remove_index :recording_studio_accesses,
                 name: "index_recording_studio_accesses_on_actor_and_role",
                 if_exists: true
    remove_index :recording_studio_accesses,
                 name: "index_recording_studio_accesses_on_actor",
                 if_exists: true

    drop_table :recording_studio_access_boundaries, if_exists: true
    drop_table :recording_studio_accesses, if_exists: true
  end

  private

  def supports_partial_indexes?
    adapter = connection.adapter_name.to_s.downcase
    adapter.include?("postgres") || adapter.include?("sqlite")
  end
end
