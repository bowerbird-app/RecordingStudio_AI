# frozen_string_literal: true

# Applies dummy migrations on an empty Postgres database.
# Run from the dummy root: ruby test/support/fresh_postgres_migration_guard.rb fresh|legacy
# SQLite ignores a drop of a missing column. This process uses Postgres.

require_relative "../../config/environment"

# Host copies from `install:migrations` are `<timestamp>_<name>.recording_studio_ai.rb`.
# The migration name is the middle part. The scope suffix is not part of the class.
module FreshPostgresMigrationGuard
  GUARD_DATABASE = "recording_studio_ai_migration_guard"
  # Stop before history integrity so dropped columns are baked into the guards.
  BEFORE_HISTORY_GUARDS = 20260811120000

  module_function

  def migration_name(filename)
    _version, name, _scope = File.basename(filename).scan(ActiveRecord::Migration::MigrationFilenameRegexp).first
    raise ArgumentError, "unrecognized migration filename #{filename}" if name.nil? || name.empty?

    name
  end

  def migration_class(filename)
    migration_name(filename).camelize.constantize
  end

  def config_for(original, database)
    hash = original.configuration_hash.deep_dup
    if hash[:url].present?
      uri = URI.parse(hash[:url])
      uri.path = "/#{database}"
      hash[:url] = uri.to_s
    end
    hash[:database] = database
    hash
  end

  def with_admin_connection(original)
    ActiveRecord::Base.establish_connection(config_for(original, "postgres"))
    yield ActiveRecord::Base.connection
  end

  def with_guard_database
    original = ActiveRecord::Base.connection_db_config
    with_admin_connection(original) do |admin|
      admin.drop_database(GUARD_DATABASE)
      admin.create_database(GUARD_DATABASE)
    end
    ActiveRecord::Base.establish_connection(config_for(original, GUARD_DATABASE))
    yield ActiveRecord::Base.connection
  ensure
    ActiveRecord::Base.establish_connection(original) if original
    if original
      with_admin_connection(original) { |admin| admin.drop_database(GUARD_DATABASE) }
      ActiveRecord::Base.establish_connection(original)
    end
  end

  def migrate_to(target)
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.connection_pool.migration_context.migrate(target)
    end
  end

  def apply_migrations_after(version, migrations_directory: Rails.root.join("db/migrate"), record_version: true)
    Dir[File.join(migrations_directory, "*.rb")].sort.each do |file|
      next if migration_version(file).to_i <= version

      apply_migration_file(file, record_version: record_version)
    end
  end

  # `record_version: false` is for a temp file that must not touch schema_migrations.
  def apply_migration_file(file, record_version: true)
    load file
    klass = migration_class(file)
    ActiveRecord::Migration.suppress_messages { klass.migrate(:up) }
    record_schema_version(file) if record_version
    klass
  end

  def migration_version(file)
    File.basename(file)[/\A(\d+)/, 1]
  end

  def record_schema_version(file)
    version = migration_version(file)
    ActiveRecord::Base.connection.execute(
      "INSERT INTO schema_migrations (version) VALUES (#{ActiveRecord::Base.connection.quote(version)})"
    )
  end

  def install_legacy_columns(connection)
    load RecordingStudioAI::Engine.root.join(
      "db/migrate/20260813120000_remove_legacy_recording_studio_ai_persistence_columns.rb"
    ).to_s
    RemoveLegacyRecordingStudioAIPersistenceColumns::LEGACY_COLUMNS.each do |table, columns|
      columns.each { |column, type| connection.add_column(table, column, type) }
    end
    connection.add_index :recording_studio_ai_runs, :input_digest, name: "idx_rsai_runs_input_digest"
    connection.add_index :recording_studio_ai_custom_tool_invocations, :arguments_digest,
                         name: "idx_rsai_tool_arguments_digest"
  end

  def install_cost_columns(connection)
    load RecordingStudioAI::Engine.root.join(
      "db/migrate/20260814130000_remove_cost_columns_from_recording_studio_ai.rb"
    ).to_s
    RemoveCostColumnsFromRecordingStudioAI::COST_COLUMNS.each do |table, columns|
      columns.each do |column|
        next if connection.column_exists?(table, column)

        connection.add_column(table, column, :string)
      end
    end
  end

  def assert_shape!(connection)
    checks = [
      [:recording_studio_ai_runs, :prompt_key, true],
      [:recording_studio_ai_runs, :provider_session_id, true],
      [:recording_studio_ai_attempts, :root_recording_id, true],
      [:recording_studio_ai_runs, :initiator_snapshot, false],
      [:recording_studio_ai_runs, :input_digest, false],
      [:recording_studio_ai_batches, :executor_snapshot, false],
      [:recording_studio_ai_custom_tool_invocations, :arguments_digest, false],
      [:recording_studio_ai_runs, :cost_amount_microunits, false],
      [:recording_studio_ai_attempts, :cost_source, false],
      [:recording_studio_ai_runs, :correlation_id, false]
    ]
    checks.each do |table, column, present|
      exists = connection.column_exists?(table, column)
      next if exists == present

      abort "#{table}.#{column} present=#{exists}, expected #{present}"
    end
    versions = connection.select_values("SELECT version FROM schema_migrations")
    %w[20260813120000 20260814130000 20261112120000].each do |version|
      abort "schema_migrations missing #{version}" unless versions.include?(version)
    end
  end

  def assert_terminal_guards!(connection)
    root_id = connection.select_value(<<~SQL)
      INSERT INTO recording_studio_recordings
        (recordable_id, recordable_type, created_at, updated_at)
      VALUES (gen_random_uuid(), 'Folder', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      RETURNING id
    SQL
    run_id = insert_execution!(connection, :recording_studio_ai_runs, root_id, status: "pending", operation: "generation")
    batch_id = insert_execution!(connection, :recording_studio_ai_batches, root_id, status: "preparing")

    update_execution!(connection, :recording_studio_ai_runs, run_id, purpose: "draft")
    update_execution!(connection, :recording_studio_ai_runs, run_id, status: "completed")
    update_execution!(connection, :recording_studio_ai_runs, run_id, metadata: "{\"kept\":true}")
    update_execution!(connection, :recording_studio_ai_runs, run_id, provider_turn_id: "turn-1")
    assert_terminal_change_blocked!(connection, :recording_studio_ai_runs, run_id, status: "cancelled")
    assert_terminal_change_blocked!(connection, :recording_studio_ai_runs, run_id, prompt_key: "summarize")

    update_execution!(connection, :recording_studio_ai_batches, batch_id, profile_key: "medium")
    update_execution!(connection, :recording_studio_ai_batches, batch_id, status: "completed")
    update_execution!(connection, :recording_studio_ai_batches, batch_id, metadata: "{\"kept\":true}")
    assert_terminal_change_blocked!(connection, :recording_studio_ai_batches, batch_id, provider: "openai")

    refute_guard_names_correlation_id!(connection)

    ActiveRecord::Migration.suppress_messages { RefreshRecordingStudioAITerminalGuards.migrate(:up) }
    update_execution!(connection, :recording_studio_ai_runs, run_id, metadata: "{\"again\":true}")
    assert_terminal_change_blocked!(connection, :recording_studio_ai_runs, run_id, purpose: "changed")
  end

  def insert_execution!(connection, table, root_id, attributes)
    columns = {
      root_recording_id: root_id,
      initiator_type: "User",
      initiator_id: "user-1",
      initiator_kind: "user",
      created_at: Time.now.utc,
      updated_at: Time.now.utc
    }.merge(attributes)
    names = columns.keys.map { |name| connection.quote_column_name(name) }
    values = columns.values.map { |value| connection.quote(value) }
    connection.select_value(
      "INSERT INTO #{table} (#{names.join(', ')}) VALUES (#{values.join(', ')}) RETURNING id"
    )
  end

  def update_execution!(connection, table, id, attributes)
    assignments = attributes.map { |name, value|
      "#{connection.quote_column_name(name)} = #{connection.quote(value)}"
    }.join(", ")
    connection.execute(
      "UPDATE #{table} SET #{assignments} WHERE #{connection.quote_column_name('id')} = #{connection.quote(id)}"
    )
  end

  def assert_terminal_change_blocked!(connection, table, id, attributes)
    update_execution!(connection, table, id, attributes)
    abort "#{table} accepted a terminal change #{attributes.inspect}"
  rescue ActiveRecord::StatementInvalid => error
    return if error.message.include?("terminal execution history is immutable")

    abort error.message
  end

  def refute_guard_names_correlation_id!(connection)
    %w[
      rsai_terminal_runs_guard
      rsai_terminal_attempts_guard
      rsai_terminal_custom_tool_invocations_guard
      rsai_terminal_batches_guard
      rsai_terminal_batch_items_guard
    ].each do |function|
      source = connection.select_value(
        "SELECT pg_get_functiondef(p.oid) FROM pg_proc p WHERE p.proname = #{connection.quote(function)}"
      )
      abort "#{function} is missing" if source.nil?
      %w[correlation_id arguments_digest input_digest cost_amount_microunits cost_source cost_category].each do |column|
        abort "#{function} still names #{column}" if source.include?(column)
      end
      abort "#{function} does not protect prompt_key" if function == "rsai_terminal_runs_guard" && !source.include?("prompt_key")
    end
  end

  def assert_related_updates!(connection, root_id)
    run_id = insert_execution!(connection, :recording_studio_ai_runs, root_id, status: "pending", operation: "generation")
    attempt_id = insert_row!(connection, :recording_studio_ai_attempts, run_id: run_id, sequence: 1, kind: "primary", status: "pending")
    invocation_id = insert_row!(
      connection, :recording_studio_ai_custom_tool_invocations,
      run_id: run_id, tool_key: "lookup", tool_version: 1, status: "requested",
      read_only: true, destructive: false, requires_confirmation: false, idempotent: true
    )
    batch_id = insert_execution!(connection, :recording_studio_ai_batches, root_id, status: "preparing")
    item_id = insert_row!(
      connection, :recording_studio_ai_batch_items,
      batch_id: batch_id, run_id: run_id, position: 0, reference: "item-1", status: "pending"
    )

    update_execution!(connection, :recording_studio_ai_attempts, attempt_id, status: "completed")
    update_execution!(connection, :recording_studio_ai_custom_tool_invocations, invocation_id, status: "completed")
    update_execution!(connection, :recording_studio_ai_batch_items, item_id, status: "completed")
    update_execution!(connection, :recording_studio_ai_attempts, attempt_id, metadata: "{\"kept\":true}")
    update_execution!(connection, :recording_studio_ai_custom_tool_invocations, invocation_id, metadata: "{\"kept\":true}")
    update_execution!(connection, :recording_studio_ai_batch_items, item_id, metadata: "{\"kept\":true}")
  end

  def insert_row!(connection, table, **attributes)
    columns = { created_at: Time.now.utc, updated_at: Time.now.utc }.merge(attributes)
    names = columns.keys.map { |name| connection.quote_column_name(name) }
    values = columns.values.map { |value| connection.quote(value) }
    connection.select_value(
      "INSERT INTO #{table} (#{names.join(', ')}) VALUES (#{values.join(', ')}) RETURNING id"
    )
  end

  def assert_legacy_indexes_gone!(connection)
    {
      recording_studio_ai_runs: "idx_rsai_runs_input_digest",
      recording_studio_ai_custom_tool_invocations: "idx_rsai_tool_arguments_digest"
    }.each do |table, name|
      abort "index #{name} still exists" if connection.index_exists?(table, name: name)
    end
  end

  def run(scenario)
    unless ActiveRecord::Base.connection.adapter_name.match?(/PostgreSQL/i)
      abort "Postgres is not available"
    end

    with_guard_database do |connection|
      case scenario
      when "fresh"
        migrate_to(nil)
        assert_shape!(connection)
        assert_terminal_guards!(connection)
      when "legacy"
        migrate_to(BEFORE_HISTORY_GUARDS)
        install_legacy_columns(connection)
        install_cost_columns(connection)
        apply_migrations_after(BEFORE_HISTORY_GUARDS)
        assert_shape!(connection)
        assert_legacy_indexes_gone!(connection)
        assert_terminal_guards!(connection)
        root_id = connection.select_value("SELECT id FROM recording_studio_recordings LIMIT 1")
        assert_related_updates!(connection, root_id)
      else
        abort "unknown scenario #{scenario}"
      end
    end

    puts "ok #{scenario}"
  end
end

FreshPostgresMigrationGuard.run(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
