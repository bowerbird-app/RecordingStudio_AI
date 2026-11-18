# frozen_string_literal: true

# A hosted turn can be stored completed before OpenAI reports usage.
# Token columns on a finished run may change only while the old value is
# null. Every other terminal column stays fixed. Other tables are unchanged.
class AllowLateHostedTurnUsageOnRecordingStudioAIRuns < ActiveRecord::Migration[8.1]
  TABLE = :recording_studio_ai_runs
  STATUSES = %w[completed failed cancelled].freeze
  MUTABLE = %w[
    id metadata lock_version created_at updated_at provider_session_id provider_turn_id
  ].freeze
  USAGE_COLUMNS = %w[
    input_tokens output_tokens total_tokens cached_input_tokens reasoning_tokens
  ].freeze

  def up
    case connection.adapter_name
    when /PostgreSQL/i
      replace_postgresql_guard
    when /SQLite/i
      replace_sqlite_guard
    else
      say "Database trigger enforcement is unavailable for #{connection.adapter_name}; model guards remain active",
          true
    end
  end

  def down
    say "late hosted turn usage columns stay fillable", true
  end

  private

  def replace_postgresql_guard
    function, trigger = guard_names
    execute "DROP TRIGGER IF EXISTS #{trigger} ON #{TABLE}"
    execute "DROP FUNCTION IF EXISTS #{function}()"
    execute <<~SQL
      CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $$
      BEGIN
        IF OLD.status IN (#{quoted_statuses}) AND (#{postgresql_comparisons}) THEN
          RAISE EXCEPTION 'terminal execution history is immutable' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
    SQL
    execute <<~SQL
      CREATE TRIGGER #{trigger}
      BEFORE UPDATE ON #{TABLE}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    SQL
  end

  def replace_sqlite_guard
    _function, trigger = guard_names
    execute "DROP TRIGGER IF EXISTS #{trigger}"
    execute <<~SQL
      CREATE TRIGGER #{trigger}
      BEFORE UPDATE ON #{TABLE}
      FOR EACH ROW
      WHEN OLD.status IN (#{quoted_statuses}) AND (#{sqlite_comparisons})
      BEGIN
        SELECT RAISE(ABORT, 'terminal execution history is immutable');
      END;
    SQL
  end

  def guard_names
    %w[rsai_terminal_runs_guard rsai_terminal_runs]
  end

  def quoted_statuses
    STATUSES.map { |status| connection.quote(status) }.join(", ")
  end

  def postgresql_comparisons
    columns = connection.columns(TABLE).index_by(&:name)
    names = columns.keys - MUTABLE - USAGE_COLUMNS
    parts = names.map { |name| distinct_from(columns.fetch(name)) }
    parts.concat(USAGE_COLUMNS.map { |name| fill_once(name, distinct: "IS DISTINCT FROM") })
    parts.join(" OR ")
  end

  def sqlite_comparisons
    names = connection.columns(TABLE).map(&:name) - MUTABLE - USAGE_COLUMNS
    parts = names.map { |name| changed(name, operator: "IS NOT") }
    parts.concat(USAGE_COLUMNS.map { |name| fill_once(name, distinct: "IS NOT") })
    parts.join(" OR ")
  end

  def distinct_from(column)
    quoted = connection.quote_column_name(column.name)
    left, right = column.sql_type == "json" ? json_sides(quoted) : plain_sides(quoted)
    "#{left} IS DISTINCT FROM #{right}"
  end

  def json_sides(quoted)
    ["(OLD.#{quoted})::jsonb", "(NEW.#{quoted})::jsonb"]
  end

  def plain_sides(quoted)
    ["OLD.#{quoted}", "NEW.#{quoted}"]
  end

  def changed(name, operator:)
    quoted = connection.quote_column_name(name)
    "OLD.#{quoted} #{operator} NEW.#{quoted}"
  end

  def fill_once(name, distinct:)
    quoted = connection.quote_column_name(name)
    "(OLD.#{quoted} IS NOT NULL AND OLD.#{quoted} #{distinct} NEW.#{quoted})"
  end
end
