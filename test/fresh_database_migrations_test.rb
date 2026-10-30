# frozen_string_literal: true

require "test_helper"

# SQLite rebuilds a table by copying column definitions. Dropping a name that
# is not in that list does nothing, so a fresh SQLite run still passes if the
# migrations drop columns that were never created. These examples check the
# resulting shape, column removal when the columns are present, and rollback
# limits. They do not prove a fresh PostgreSQL install. That guard is
# FreshPostgresMigrationsTest in the dummy app. CI runs it against Postgres.
# `rake test:fresh_migrate` applies the same empty-database chain.
class FreshDatabaseMigrationsTest < Minitest::Test
  include RecordingStudioAI::Test::Persistence

  LEGACY_MIGRATION = "20260813120000"
  COST_MIGRATION = "20260814130000"

  def setup
    RecordingStudioAI::Test::Persistence.load!
    connect_sqlite_memory!
    bootstrap_host_tables!
  end

  def teardown
    disconnect_sqlite!
  end

  def test_every_shipped_migration_applies_on_an_empty_sqlite_database
    apply(migrations)

    assert column_exists?(:recording_studio_ai_runs, :prompt_key)
    assert column_exists?(:recording_studio_ai_runs, :provider_session_id)
    assert column_exists?(:recording_studio_ai_attempts, :root_recording_id)
    assert_legacy_columns_absent
    assert_cost_columns_absent
    refute column_exists?(:recording_studio_ai_runs, :prompt_namespace)
    refute column_exists?(:recording_studio_ai_runs, :correlation_id)
  end

  def test_legacy_columns_and_indexes_are_removed_when_present
    apply(migrations_before(LEGACY_MIGRATION))
    install_legacy_columns
    add_index :recording_studio_ai_runs, :initiator_snapshot, name: "idx_rsai_runs_initiator_snapshot"
    add_index :recording_studio_ai_batches, %i[executor_snapshot created_at],
              name: "idx_rsai_batches_executor_snapshot_created_at"

    apply(migrations_from(LEGACY_MIGRATION))

    assert_legacy_columns_absent
    refute index_exists?(:recording_studio_ai_runs, name: "idx_rsai_runs_initiator_snapshot")
    refute index_exists?(:recording_studio_ai_batches, name: "idx_rsai_batches_executor_snapshot_created_at")
    assert column_exists?(:recording_studio_ai_runs, :provider_session_id)
    assert_cost_columns_absent
  end

  def test_legacy_migration_down_restores_missing_columns_without_indexes
    apply(migrations_before(LEGACY_MIGRATION))
    install_legacy_columns
    add_index :recording_studio_ai_runs, :input_digest, name: "idx_rsai_runs_input_digest"
    apply([[LEGACY_MIGRATION, migration_class(LEGACY_MIGRATION)]])
    refute index_exists?(:recording_studio_ai_runs, name: "idx_rsai_runs_input_digest")

    migration = migration_class(LEGACY_MIGRATION)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }

    assert_legacy_columns_present
    refute index_exists?(:recording_studio_ai_runs, name: "idx_rsai_runs_input_digest")
    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    assert_legacy_columns_present
    refute index_exists?(:recording_studio_ai_runs, name: "idx_rsai_runs_input_digest")
  end

  def test_cost_migration_down_raises_when_a_cost_column_is_still_present
    apply(migrations_before(COST_MIGRATION))
    add_column :recording_studio_ai_runs, :cost_amount_microunits, :bigint

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      ActiveRecord::Migration.suppress_messages { RemoveCostColumnsFromRecordingStudioAI.migrate(:down) }
    end

    assert_match(/remove_column is only reversible if given a type/, error.message)
    assert column_exists?(:recording_studio_ai_runs, :cost_amount_microunits)
  end

  def test_cost_columns_are_removed_when_present
    apply(migrations_before(COST_MIGRATION))
    RemoveCostColumnsFromRecordingStudioAI::COST_COLUMNS.each do |table, columns|
      columns.each { |column| add_column table, column, :string }
    end

    apply(migrations_from(COST_MIGRATION))

    assert_cost_columns_absent
    assert column_exists?(:recording_studio_ai_attempts, :root_recording_id)
  end

  private

  def migrations
    @migrations ||= Dir[File.join(RecordingStudioAI::Test::Persistence::GEM_ROOT, "db/migrate/*.rb")].map do |file|
      version = File.basename(file)[/\A(\d+)/, 1]
      [version, Object.const_get(File.read(file)[/^class ([A-Z]\w+)/, 1])]
    end
  end

  def migrations_before(version)
    migrations.take_while { |migration_version, _klass| migration_version < version }
  end

  def migrations_from(version)
    migrations.drop_while { |migration_version, _klass| migration_version < version }
  end

  def migration_class(version)
    migrations.find { |migration_version, _klass| migration_version == version }.last
  end

  def apply(list)
    ActiveRecord::Migration.suppress_messages do
      list.each { |pair| pair.last.migrate(:up) }
    end
  end

  def install_legacy_columns
    RemoveLegacyRecordingStudioAIPersistenceColumns::LEGACY_COLUMNS.each do |table, columns|
      columns.each { |column, type| add_column table, column, type }
    end
  end

  def add_column(table, column, type)
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.connection.add_column(table, column, type)
    end
  end

  def add_index(table, columns, name:)
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Base.connection.add_index(table, columns, name: name)
    end
  end

  def column_exists?(table, column)
    ActiveRecord::Base.connection.column_exists?(table, column)
  end

  def index_exists?(table, name:)
    ActiveRecord::Base.connection.index_exists?(table, name: name)
  end

  def assert_legacy_columns_absent
    each_legacy_column do |table, column|
      refute column_exists?(table, column), "#{table}.#{column} should be absent"
    end
  end

  def assert_legacy_columns_present
    each_legacy_column do |table, column|
      assert column_exists?(table, column), "#{table}.#{column} should be present"
    end
  end

  def each_legacy_column(&block)
    RemoveLegacyRecordingStudioAIPersistenceColumns::LEGACY_COLUMNS.each do |table, columns|
      columns.each_key { |column| block.call(table, column) }
    end
  end

  def assert_cost_columns_absent
    RemoveCostColumnsFromRecordingStudioAI::COST_COLUMNS.each do |table, columns|
      columns.each do |column|
        refute column_exists?(table, column), "#{table}.#{column} should be absent"
      end
    end
  end
end
