# frozen_string_literal: true

# History integrity builds rsai_terminal_* from the columns present at that
# moment. Later migrations drop correlation_id, legacy digests, and cost
# columns without replacing the functions. PostgreSQL then rejects every
# update. SQLite drops every trigger on a rewritten table, including
# ownership and relationship guards. Rebuild the terminal guards from the
# columns that exist now, and put the SQLite ownership triggers back.
# provider_session_id and provider_turn_id stay writable so a finished run
# can record a turn id. prompt_* columns do not.
module RefreshRecordingStudioAISqliteGuards
  def recreate_sqlite_ownership_and_relationship_guards
    sqlite_ownership_guards.each do |name, (table, columns)|
      replace_sqlite_ownership_guard(name, table, columns)
    end
    %w[INSERT UPDATE].each { |event| recreate_sqlite_relationship_guards(event) }
  end

  def sqlite_ownership_guards
    {
      "attempt_run" => [:recording_studio_ai_attempts, %w[run_id]],
      "run_root" => [:recording_studio_ai_runs, %w[root_recording_id context_recording_id]],
      "batch_root" => [:recording_studio_ai_batches, %w[root_recording_id context_recording_id]]
    }
  end

  def replace_sqlite_ownership_guard(name, table, columns)
    trigger = "rsai_#{name}_ownership_guard"
    execute "DROP TRIGGER IF EXISTS #{trigger}"
    execute <<~SQL
      CREATE TRIGGER #{trigger}
      BEFORE UPDATE ON #{table}
      FOR EACH ROW
      WHEN #{changed(columns)}
      BEGIN
        SELECT RAISE(ABORT, 'execution ownership columns are immutable');
      END;
    SQL
  end

  # Same checks as EnforceRecordingStudioAIHistoryIntegrity.
  def recreate_sqlite_relationship_guards(event)
    suffix = event.downcase
    execute "DROP TRIGGER IF EXISTS rsai_invocation_attempt_run_guard_#{suffix}"
    execute <<~SQL
      CREATE TRIGGER rsai_invocation_attempt_run_guard_#{suffix}
      BEFORE #{event} ON recording_studio_ai_custom_tool_invocations
      FOR EACH ROW
      WHEN (NEW.requested_by_attempt_id IS NOT NULL AND
            (SELECT run_id FROM recording_studio_ai_attempts WHERE id = NEW.requested_by_attempt_id) IS NOT NEW.run_id)
        OR (NEW.continued_by_attempt_id IS NOT NULL AND
            (SELECT run_id FROM recording_studio_ai_attempts WHERE id = NEW.continued_by_attempt_id) IS NOT NEW.run_id)
      BEGIN
        SELECT RAISE(ABORT, 'invocation attempts must belong to invocation run');
      END;
    SQL
    execute "DROP TRIGGER IF EXISTS rsai_batch_item_root_guard_#{suffix}"
    execute <<~SQL
      CREATE TRIGGER rsai_batch_item_root_guard_#{suffix}
      BEFORE #{event} ON recording_studio_ai_batch_items
      FOR EACH ROW
      WHEN EXISTS (
        SELECT 1 FROM recording_studio_ai_runs runs, recording_studio_ai_batches batches
        WHERE runs.id = NEW.run_id AND batches.id = NEW.batch_id
          AND (runs.root_recording_id IS NOT batches.root_recording_id OR
               runs.context_recording_id IS NOT batches.context_recording_id)
      )
      BEGIN
        SELECT RAISE(ABORT, 'batch item run must match batch attribution');
      END;
    SQL
  end
end

class RefreshRecordingStudioAITerminalGuards < ActiveRecord::Migration[8.1]
  include RefreshRecordingStudioAISqliteGuards

  TABLES = {
    recording_studio_ai_runs: %w[completed failed cancelled],
    recording_studio_ai_attempts: %w[completed failed cancelled],
    recording_studio_ai_custom_tool_invocations: %w[completed denied rejected failed cancelled],
    recording_studio_ai_batches: %w[completed partially_completed failed cancelled expired],
    recording_studio_ai_batch_items: %w[completed failed cancelled expired]
  }.freeze
  MUTABLE = %w[
    id metadata lock_version created_at updated_at provider_session_id provider_turn_id
  ].freeze

  def up
    case connection.adapter_name
    when /PostgreSQL/i
      TABLES.each { |table, statuses| replace_postgresql_guard(table, statuses) }
    when /SQLite/i
      TABLES.each { |table, statuses| replace_sqlite_guard(table, statuses) }
      recreate_sqlite_ownership_and_relationship_guards
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
      WHEN OLD.status IN (#{quoted_statuses(statuses)}) AND (#{changed(connection.columns(table).map(&:name) - MUTABLE)})
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

  def postgresql_comparisons(table)
    columns = connection.columns(table).index_by(&:name)
    names = columns.keys - MUTABLE
    names.map { |name| postgresql_comparison(columns.fetch(name)) }.join(" OR ")
  end

  def postgresql_comparison(column)
    quoted = connection.quote_column_name(column.name)
    json = ["(OLD.#{quoted})::jsonb", "(NEW.#{quoted})::jsonb"]
    plain = ["OLD.#{quoted}", "NEW.#{quoted}"]
    (column.sql_type == "json" ? json : plain).join(" IS DISTINCT FROM ")
  end

  def changed(names)
    names.map do |name|
      quoted = connection.quote_column_name(name)
      "OLD.#{quoted} IS NOT NEW.#{quoted}"
    end.join(" OR ")
  end
end
