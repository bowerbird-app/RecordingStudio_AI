# frozen_string_literal: true

# History integrity builds rsai_terminal_* while correlation_id still exists.
# The later drop never replaces those guards. PostgreSQL then raises
# "record old has no field correlation_id" on every run or batch update.
# SQLite drops the triggers when it rewrites the table. Rebuild both from
# the columns that exist now. Mutable columns and terminal statuses stay
# the same as the original guards.
class RefreshRecordingStudioAITerminalGuards < ActiveRecord::Migration[8.1]
  TABLES = {
    recording_studio_ai_runs: %w[completed failed cancelled],
    recording_studio_ai_batches: %w[completed partially_completed failed cancelled expired]
  }.freeze
  MUTABLE = %w[id metadata lock_version created_at updated_at].freeze

  def up
    case connection.adapter_name
    when /PostgreSQL/i
      TABLES.each { |table, statuses| replace_postgresql_guard(table, statuses) }
    when /SQLite/i
      TABLES.each { |table, statuses| replace_sqlite_guard(table, statuses) }
    else
      say "Database trigger enforcement is unavailable for #{connection.adapter_name}; model guards remain active", true
    end
  end

  # Rolling back would restore a function that names a dropped column.
  def down
    say "terminal guards stay rebuilt", true
  end

  private

  def replace_postgresql_guard(table, statuses)
    function, trigger = guard_names(table)
    execute "DROP TRIGGER IF EXISTS #{trigger} ON #{table}"
    execute "DROP FUNCTION IF EXISTS #{function}()"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $$
      BEGIN
        IF OLD.status IN (#{quoted_statuses(statuses)}) AND (#{postgresql_comparisons(table)}) THEN
          RAISE EXCEPTION 'terminal execution history is immutable' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER #{trigger}
      BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    SQL
  end

  def replace_sqlite_guard(table, statuses)
    _function, trigger = guard_names(table)
    execute "DROP TRIGGER IF EXISTS #{trigger}"
    execute <<~SQL
      CREATE TRIGGER #{trigger}
      BEFORE UPDATE ON #{table}
      FOR EACH ROW
      WHEN OLD.status IN (#{quoted_statuses(statuses)}) AND (#{sqlite_comparisons(table)})
      BEGIN
        SELECT RAISE(ABORT, 'terminal execution history is immutable');
      END;
    SQL
  end

  def guard_names(table)
    suffix = table.to_s.delete_prefix("recording_studio_ai_")
    ["rsai_terminal_#{suffix}_guard", "rsai_terminal_#{suffix}"]
  end

  def quoted_statuses(statuses)
    statuses.map { |status| connection.quote(status) }.join(", ")
  end

  def immutable_names(table)
    connection.columns(table).map(&:name) - MUTABLE
  end

  def postgresql_comparisons(table)
    columns = connection.columns(table).index_by(&:name)
    immutable_names(table).map { |name| postgresql_comparison(columns.fetch(name)) }.join(" OR ")
  end

  def postgresql_comparison(column)
    quoted = connection.quote_column_name(column.name)
    if column.sql_type == "json"
      "(OLD.#{quoted})::jsonb IS DISTINCT FROM (NEW.#{quoted})::jsonb"
    else
      "OLD.#{quoted} IS DISTINCT FROM NEW.#{quoted}"
    end
  end

  def sqlite_comparisons(table)
    immutable_names(table).map do |name|
      quoted = connection.quote_column_name(name)
      "OLD.#{quoted} IS NOT NEW.#{quoted}"
    end.join(" OR ")
  end
end
