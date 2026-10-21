# frozen_string_literal: true

class CreateRecordingStudioAICallLogSummaries < ActiveRecord::Migration[8.1]
  ATTEMPT_TABLE = "recording_studio_ai_attempt_day_summaries"
  TOOL_TABLE = "recording_studio_ai_tool_call_day_summaries"
  ATTEMPT_IDENTITY = "index_rsai_attempt_day_summaries_identity"
  TOOL_IDENTITY = "index_rsai_tool_call_day_summaries_identity"

  def up
    RecordingStudioLogs::Schema.install_runs!(connection)
    create_attempt_summaries
    create_tool_summaries
  end

  def down
    drop_table ATTEMPT_TABLE if connection.data_source_exists?(ATTEMPT_TABLE)
    drop_table TOOL_TABLE if connection.data_source_exists?(TOOL_TABLE)
  end

  private

  def create_attempt_summaries
    return if connection.data_source_exists?(ATTEMPT_TABLE)

    create_table ATTEMPT_TABLE, **summary_table_options, &attempt_summary_columns
    add_summary_index(
      ATTEMPT_TABLE,
      %i[day root_recording_id provider model status],
      name: ATTEMPT_IDENTITY
    )
    add_index ATTEMPT_TABLE, %i[root_recording_id day], name: "index_rsai_attempt_day_summaries_on_root_and_day"
  end

  def create_tool_summaries
    return if connection.data_source_exists?(TOOL_TABLE)

    create_table TOOL_TABLE, **summary_table_options, &tool_summary_columns
    add_summary_index(
      TOOL_TABLE,
      %i[day root_recording_id tool_key status],
      name: TOOL_IDENTITY
    )
    add_index TOOL_TABLE, %i[root_recording_id day], name: "index_rsai_tool_call_day_summaries_on_root_and_day"
  end

  def attempt_summary_columns
    lambda do |t|
      t.date :day, null: false
      t.column :root_recording_id, root_recording_id_type
      t.string :provider
      t.string :model
      t.string :status
      t.bigint :call_count, null: false, default: 0
      t.bigint :latency_sum_ms, null: false, default: 0
      t.bigint :latency_max_ms, null: false, default: 0
      t.timestamps
    end
  end

  def tool_summary_columns
    lambda do |t|
      t.date :day, null: false
      t.column :root_recording_id, root_recording_id_type
      t.string :tool_key
      t.string :status
      t.bigint :tool_call_count, null: false, default: 0
      t.bigint :latency_sum_ms, null: false, default: 0
      t.timestamps
    end
  end

  def summary_table_options
    if connection.adapter_name.match?(/PostgreSQL/i)
      { id: :uuid, default: -> { "gen_random_uuid()" } }
    else
      {}
    end
  end

  def root_recording_id_type
    connection.columns(:recording_studio_ai_runs).find { |column| column.name == "root_recording_id" }.type
  end

  def add_summary_index(table, columns, name:)
    if connection.adapter_name.match?(/PostgreSQL/i)
      RecordingStudioLogs::Schema.summary_index(table, columns, name: name, connection: connection)
    else
      add_index table, columns, unique: true, name: name
    end
  end
end
