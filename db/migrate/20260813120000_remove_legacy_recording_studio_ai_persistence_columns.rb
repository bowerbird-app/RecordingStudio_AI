# frozen_string_literal: true

class RemoveLegacyRecordingStudioAIPersistenceColumns < ActiveRecord::Migration[8.1]
  # Fresh installs never create these columns. Older hosts may still have them,
  # sometimes with an index. Snapshots were JSON; digests were strings.
  LEGACY_COLUMNS = {
    recording_studio_ai_runs: {
      initiator_snapshot: :json,
      executor_snapshot: :json,
      impersonator_snapshot: :json,
      input_digest: :string,
      output_digest: :string
    },
    recording_studio_ai_custom_tool_invocations: {
      arguments_digest: :string,
      arguments_summary: :text,
      result_digest: :string
    },
    recording_studio_ai_batches: {
      initiator_snapshot: :json,
      executor_snapshot: :json,
      impersonator_snapshot: :json
    }
  }.freeze

  def up
    LEGACY_COLUMNS.each do |table, columns|
      columns.each_key { |column| remove_legacy_column(table, column) }
    end
  end

  def down
    LEGACY_COLUMNS.each do |table, columns|
      columns.each { |column, type| restore_legacy_column(table, column, type) }
    end
  end

  private

  def remove_legacy_column(table, column)
    return unless column_exists?(table, column)

    remove_legacy_indexes(table, column)
    remove_column table, column if column_exists?(table, column)
  end

  def remove_legacy_indexes(table, column)
    connection.indexes(table).each do |index|
      next unless index_includes?(index, column)
      next unless index_exists?(table, name: index.name)

      remove_index table, name: index.name
    end
  end

  def index_includes?(index, column)
    Array(index.columns).map(&:to_s).include?(column.to_s)
  end

  def restore_legacy_column(table, column, type)
    add_column table, column, type unless column_exists?(table, column)
  end
end
