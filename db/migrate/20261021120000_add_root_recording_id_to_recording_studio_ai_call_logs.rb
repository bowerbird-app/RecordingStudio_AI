# frozen_string_literal: true

class AddRootRecordingIdToRecordingStudioAICallLogs < ActiveRecord::Migration[8.1]
  TABLES = {
    recording_studio_ai_attempts: "idx_rsai_attempts_root_created_at",
    recording_studio_ai_custom_tool_invocations: "idx_rsai_tool_invocations_root_created_at"
  }.freeze

  def up
    TABLES.each do |table, index_name|
      add_root_column(table)
      backfill_from_runs(table)
      next if index_exists?(table, %i[root_recording_id created_at], name: index_name)

      add_index table, %i[root_recording_id created_at], name: index_name
    end
  end

  def down
    TABLES.each do |table, index_name|
      remove_index table, name: index_name if index_exists?(table, name: index_name)
      remove_column table, :root_recording_id if column_exists?(table, :root_recording_id)
    end
  end

  private

  def add_root_column(table)
    return if column_exists?(table, :root_recording_id)

    add_column table, :root_recording_id, root_recording_id_type
  end

  def root_recording_id_type
    connection.columns(:recording_studio_ai_runs).find { |column| column.name == "root_recording_id" }.type
  end

  def backfill_from_runs(table)
    quoted_table = connection.quote_table_name(table)
    quoted_root = connection.quote_column_name("root_recording_id")
    quoted_run_id = connection.quote_column_name("run_id")
    quoted_runs = connection.quote_table_name("recording_studio_ai_runs")

    if connection.adapter_name.match?(/PostgreSQL/i)
      execute <<~SQL.squish
        UPDATE #{quoted_table} AS logs
        SET #{quoted_root} = runs.root_recording_id
        FROM #{quoted_runs} AS runs
        WHERE logs.#{quoted_run_id} = runs.id
          AND logs.#{quoted_root} IS NULL
      SQL
    else
      execute <<~SQL.squish
        UPDATE #{quoted_table}
        SET #{quoted_root} = (
          SELECT runs.root_recording_id FROM #{quoted_runs} AS runs
          WHERE runs.id = #{quoted_table}.#{quoted_run_id}
        )
        WHERE #{quoted_root} IS NULL
      SQL
    end
  end
end
