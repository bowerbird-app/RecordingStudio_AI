# frozen_string_literal: true

class EnforceRecordingStudioAIHistoryIntegrity < ActiveRecord::Migration[8.1]
  TERMINAL_TABLES = {
    recording_studio_ai_runs: %w[completed failed cancelled],
    recording_studio_ai_attempts: %w[completed failed cancelled],
    recording_studio_ai_custom_tool_invocations: %w[completed denied rejected failed cancelled],
    recording_studio_ai_batches: %w[completed partially_completed failed cancelled expired],
    recording_studio_ai_batch_items: %w[completed failed cancelled expired]
  }.freeze
  MUTABLE_TERMINAL_COLUMNS = %w[id metadata lock_version created_at updated_at].freeze

  def up
    case connection.adapter_name
    when /PostgreSQL/i
      create_postgresql_terminal_guards
      create_postgresql_relationship_guards
      create_postgresql_ownership_guards
    when /SQLite/i
      create_sqlite_terminal_guards
      create_sqlite_relationship_guards
      create_sqlite_ownership_guards
    else
      say "Database trigger enforcement is unavailable for #{connection.adapter_name}; model guards remain active", true
    end
  end

  def down
    case connection.adapter_name
    when /PostgreSQL/i
      TERMINAL_TABLES.each_key do |table|
        execute "DROP TRIGGER IF EXISTS #{terminal_trigger(table)} ON #{table}"
        execute "DROP FUNCTION IF EXISTS #{terminal_function(table)}()"
      end
      execute "DROP TRIGGER IF EXISTS rsai_invocation_attempt_run_guard ON recording_studio_ai_custom_tool_invocations"
      execute "DROP FUNCTION IF EXISTS rsai_check_invocation_attempt_run()"
      execute "DROP TRIGGER IF EXISTS rsai_batch_item_root_guard ON recording_studio_ai_batch_items"
      execute "DROP FUNCTION IF EXISTS rsai_check_batch_item_root()"
      {
        "attempt_run" => "recording_studio_ai_attempts",
        "run_root" => "recording_studio_ai_runs",
        "batch_root" => "recording_studio_ai_batches"
      }.each do |name, table|
        execute "DROP TRIGGER IF EXISTS rsai_#{name}_ownership_guard ON #{table}"
        execute "DROP FUNCTION IF EXISTS rsai_check_#{name}_ownership()"
      end
    when /SQLite/i
      TERMINAL_TABLES.each_key { |table| execute "DROP TRIGGER IF EXISTS #{terminal_trigger(table)}" }
      %w[insert update].each do |event|
        execute "DROP TRIGGER IF EXISTS rsai_invocation_attempt_run_guard_#{event}"
        execute "DROP TRIGGER IF EXISTS rsai_batch_item_root_guard_#{event}"
      end
      %w[attempt_run run_root batch_root].each do |name|
        execute "DROP TRIGGER IF EXISTS rsai_#{name}_ownership_guard"
      end
    end
  end

  private

  def immutable_columns(table)
    connection.columns(table).map(&:name) - MUTABLE_TERMINAL_COLUMNS
  end

  def terminal_trigger(table) = "rsai_terminal_#{table.to_s.delete_prefix('recording_studio_ai_')}"
  def terminal_function(table) = "#{terminal_trigger(table)}_guard"

  def quoted_statuses(statuses)
    statuses.map { |status| connection.quote(status) }.join(", ")
  end

  def create_postgresql_terminal_guards
    TERMINAL_TABLES.each do |table, statuses|
      columns = connection.columns(table).index_by(&:name)
      comparisons = immutable_columns(table).map do |column|
        quoted = connection.quote_column_name(column)
        if columns.fetch(column).sql_type == "json"
          "(OLD.#{quoted})::jsonb IS DISTINCT FROM (NEW.#{quoted})::jsonb"
        else
          "OLD.#{quoted} IS DISTINCT FROM NEW.#{quoted}"
        end
      end.join(" OR ")
      execute <<~SQL
        CREATE FUNCTION #{terminal_function(table)}() RETURNS trigger AS $$
        BEGIN
          IF OLD.status IN (#{quoted_statuses(statuses)}) AND (#{comparisons}) THEN
            RAISE EXCEPTION 'terminal execution history is immutable' USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      execute <<~SQL
        CREATE TRIGGER #{terminal_trigger(table)}
        BEFORE UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION #{terminal_function(table)}();
      SQL
    end
  end

  def create_sqlite_terminal_guards
    TERMINAL_TABLES.each do |table, statuses|
      comparisons = immutable_columns(table).map do |column|
        quoted = connection.quote_column_name(column)
        "OLD.#{quoted} IS NOT NEW.#{quoted}"
      end.join(" OR ")
      execute <<~SQL
        CREATE TRIGGER #{terminal_trigger(table)}
        BEFORE UPDATE ON #{table}
        FOR EACH ROW
        WHEN OLD.status IN (#{quoted_statuses(statuses)}) AND (#{comparisons})
        BEGIN
          SELECT RAISE(ABORT, 'terminal execution history is immutable');
        END;
      SQL
    end
  end

  def create_postgresql_relationship_guards
    execute <<~SQL
      CREATE FUNCTION rsai_check_invocation_attempt_run() RETURNS trigger AS $$
      BEGIN
        IF NEW.requested_by_attempt_id IS NOT NULL AND
           (SELECT run_id FROM recording_studio_ai_attempts WHERE id = NEW.requested_by_attempt_id) IS DISTINCT FROM NEW.run_id THEN
          RAISE EXCEPTION 'requested attempt must belong to invocation run' USING ERRCODE = 'foreign_key_violation';
        END IF;
        IF NEW.continued_by_attempt_id IS NOT NULL AND
           (SELECT run_id FROM recording_studio_ai_attempts WHERE id = NEW.continued_by_attempt_id) IS DISTINCT FROM NEW.run_id THEN
          RAISE EXCEPTION 'continued attempt must belong to invocation run' USING ERRCODE = 'foreign_key_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER rsai_invocation_attempt_run_guard
      BEFORE INSERT OR UPDATE ON recording_studio_ai_custom_tool_invocations
      FOR EACH ROW EXECUTE FUNCTION rsai_check_invocation_attempt_run();
    SQL

    execute <<~SQL
      CREATE FUNCTION rsai_check_batch_item_root() RETURNS trigger AS $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM recording_studio_ai_runs runs, recording_studio_ai_batches batches
          WHERE runs.id = NEW.run_id AND batches.id = NEW.batch_id
            AND (runs.root_recording_id IS DISTINCT FROM batches.root_recording_id OR
                 runs.context_recording_id IS DISTINCT FROM batches.context_recording_id)
        ) THEN
          RAISE EXCEPTION 'batch item run must match batch attribution' USING ERRCODE = 'foreign_key_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER rsai_batch_item_root_guard
      BEFORE INSERT OR UPDATE ON recording_studio_ai_batch_items
      FOR EACH ROW EXECUTE FUNCTION rsai_check_batch_item_root();
    SQL
  end

  def create_sqlite_relationship_guards
    %w[INSERT UPDATE].each do |event|
      suffix = event.downcase
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

  def create_postgresql_ownership_guards
    create_postgresql_immutable_columns_guard(
      table: :recording_studio_ai_attempts, name: :attempt_run, columns: %w[run_id]
    )
    create_postgresql_immutable_columns_guard(
      table: :recording_studio_ai_runs, name: :run_root, columns: %w[root_recording_id context_recording_id]
    )
    create_postgresql_immutable_columns_guard(
      table: :recording_studio_ai_batches, name: :batch_root, columns: %w[root_recording_id context_recording_id]
    )
  end

  def create_postgresql_immutable_columns_guard(table:, name:, columns:)
    comparisons = columns.map { |column| "OLD.#{column} IS DISTINCT FROM NEW.#{column}" }.join(" OR ")
    execute <<~SQL
      CREATE FUNCTION rsai_check_#{name}_ownership() RETURNS trigger AS $$
      BEGIN
        IF #{comparisons} THEN
          RAISE EXCEPTION 'execution ownership columns are immutable' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER rsai_#{name}_ownership_guard
      BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION rsai_check_#{name}_ownership();
    SQL
  end

  def create_sqlite_ownership_guards
    create_sqlite_immutable_columns_guard(
      table: :recording_studio_ai_attempts, name: :attempt_run, columns: %w[run_id]
    )
    create_sqlite_immutable_columns_guard(
      table: :recording_studio_ai_runs, name: :run_root, columns: %w[root_recording_id context_recording_id]
    )
    create_sqlite_immutable_columns_guard(
      table: :recording_studio_ai_batches, name: :batch_root, columns: %w[root_recording_id context_recording_id]
    )
  end

  def create_sqlite_immutable_columns_guard(table:, name:, columns:)
    comparisons = columns.map { |column| "OLD.#{column} IS NOT NEW.#{column}" }.join(" OR ")
    execute <<~SQL
      CREATE TRIGGER rsai_#{name}_ownership_guard
      BEFORE UPDATE ON #{table}
      FOR EACH ROW
      WHEN #{comparisons}
      BEGIN
        SELECT RAISE(ABORT, 'execution ownership columns are immutable');
      END;
    SQL
  end
end
