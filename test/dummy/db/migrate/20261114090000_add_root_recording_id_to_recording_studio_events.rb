# frozen_string_literal: true

class AddRootRecordingIdToRecordingStudioEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_events, :root_recording_id, :uuid
    backfill_event_root_recording_ids
    change_column_null :recording_studio_events, :root_recording_id, false
    add_foreign_key :recording_studio_events, :recording_studio_recordings, column: :root_recording_id
    add_root_timeline_index
    add_impersonator_index
  end

  def down
    remove_foreign_key :recording_studio_events, column: :root_recording_id
    remove_index :recording_studio_events, name: "index_rs_events_on_root_and_timeline"
    remove_index :recording_studio_events, name: "index_rs_events_on_impersonator_and_occurred_at"
    remove_column :recording_studio_events, :root_recording_id
  end

  private

  def backfill_event_root_recording_ids
    execute <<~SQL.squish
      UPDATE recording_studio_events AS events
      SET root_recording_id = COALESCE(recordings.root_recording_id, recordings.id)
      FROM recording_studio_recordings AS recordings
      WHERE recordings.id = events.recording_id
    SQL
  end

  def add_root_timeline_index
    add_index :recording_studio_events,
              %i[root_recording_id occurred_at created_at id],
              order: { occurred_at: :desc, created_at: :desc, id: :desc },
              name: "index_rs_events_on_root_and_timeline"
  end

  def add_impersonator_index
    add_index :recording_studio_events,
              %i[impersonator_type impersonator_id occurred_at],
              name: "index_rs_events_on_impersonator_and_occurred_at"
  end
end
