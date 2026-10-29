# frozen_string_literal: true

# Applies dummy migrations on an empty Postgres database.
# Run from the dummy root: ruby test/support/fresh_postgres_migration_guard.rb fresh|legacy
# SQLite ignores a drop of a missing column. This process uses Postgres.

require_relative "../../config/environment"

# Host copies from `install:migrations` are `<timestamp>_<name>.recording_studio_ai.rb`.
# The migration name is the middle part. The scope suffix is not part of the class.
module FreshPostgresMigrationGuard
  def self.migration_name(filename)
    _version, name, _scope = File.basename(filename).scan(ActiveRecord::Migration::MigrationFilenameRegexp).first
    raise ArgumentError, "unrecognized migration filename #{filename}" if name.nil? || name.empty?

    name
  end

  def self.migration_class(filename)
    migration_name(filename).camelize.constantize
  end
end

GUARD_DATABASE = "recording_studio_ai_migration_guard"
LEGACY_STOP = 20260812150000

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

def apply_migrations_after(version)
  Dir[Rails.root.join("db/migrate/*.rb").to_s].sort.each do |file|
    file_version = File.basename(file)[/\A(\d+)/, 1]
    next if file_version.to_i <= version

    load file
    klass = FreshPostgresMigrationGuard.migration_class(file)
    ActiveRecord::Migration.suppress_messages { klass.migrate(:up) }
    ActiveRecord::Base.connection.execute(
      "INSERT INTO schema_migrations (version) VALUES (#{ActiveRecord::Base.connection.quote(file_version)})"
    )
  end
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
  %w[20260813120000 20260814130000].each do |version|
    abort "schema_migrations missing #{version}" unless versions.include?(version)
  end
end

def assert_legacy_indexes_gone!(connection)
  {
    recording_studio_ai_runs: "idx_rsai_runs_input_digest",
    recording_studio_ai_custom_tool_invocations: "idx_rsai_tool_arguments_digest"
  }.each do |table, name|
    abort "index #{name} still exists" if connection.index_exists?(table, name: name)
  end
end

if $PROGRAM_NAME == __FILE__
  scenario = ARGV.fetch(0)
  unless ActiveRecord::Base.connection.adapter_name.match?(/PostgreSQL/i)
    abort "Postgres is not available"
  end

  with_guard_database do |connection|
    case scenario
    when "fresh"
      migrate_to(nil)
      assert_shape!(connection)
    when "legacy"
      migrate_to(LEGACY_STOP)
      install_legacy_columns(connection)
      apply_migrations_after(LEGACY_STOP)
      assert_shape!(connection)
      assert_legacy_indexes_gone!(connection)
    else
      abort "unknown scenario #{scenario}"
    end
  end

  puts "ok #{scenario}"
end
