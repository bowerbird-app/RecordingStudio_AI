# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# PostgreSQL raises PG::UndefinedColumn when a migration drops a column that
# was never created. SQLite does not. Each scenario runs in its own process
# because Rails removes a migration constant and then `require`s a file that
# is already loaded. CI's test job provides Postgres. `rake test:fresh_migrate`
# applies the same empty-database chain.
class FreshPostgresMigrationsTest < ActiveSupport::TestCase
  SKIP_MESSAGE = "Postgres is not available, so this fresh-database migration guard did not run. " \
                 "SQLite ignores a drop of a missing column, so the gem suite cannot catch that failure. " \
                 "CI runs this test on Postgres. `rake test:fresh_migrate` applies the same empty-database chain."

  test "every migration applies on an empty postgres database" do
    skip SKIP_MESSAGE unless postgres_available?

    run_scenario("fresh")
  end

  test "legacy columns and indexes are removed when present on postgres" do
    skip SKIP_MESSAGE unless postgres_available?

    run_scenario("legacy")
  end

  test "host copies with the recording_studio_ai suffix use the migration name" do
    require Rails.root.join("test/support/fresh_postgres_migration_guard.rb").to_s
    %w[
      20260813120000_remove_legacy_recording_studio_ai_persistence_columns.rb
      20260814130000_remove_cost_columns_from_recording_studio_ai.rb
    ].each { |file| load RecordingStudioAI::Engine.root.join("db/migrate", file).to_s }

    {
      "remove_legacy_recording_studio_ai_persistence_columns" =>
        "RemoveLegacyRecordingStudioAIPersistenceColumns",
      "remove_cost_columns_from_recording_studio_ai" =>
        "RemoveCostColumnsFromRecordingStudioAI"
    }.each do |migration_name, class_name|
      plain = "db/migrate/20260813120000_#{migration_name}.rb"
      copied = "db/migrate/20261029183000_#{migration_name}.recording_studio_ai.rb"

      assert_equal migration_name, FreshPostgresMigrationGuard.migration_name(plain)
      assert_equal migration_name, FreshPostgresMigrationGuard.migration_name(copied)
      assert_equal class_name, FreshPostgresMigrationGuard.migration_name(copied).camelize
      assert_equal FreshPostgresMigrationGuard.migration_class(plain),
                   FreshPostgresMigrationGuard.migration_class(copied)
      assert_equal class_name, FreshPostgresMigrationGuard.migration_class(copied).name
    end
  end

  test "apply_migration_file loads a scope-suffixed filename" do
    require Rails.root.join("test/support/fresh_postgres_migration_guard.rb").to_s
    refute_operator Object, :const_defined?, :GUARD_DATABASE
    refute Object.private_method_defined?(:apply_migration_file)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "20261029183000_guard_suffix_probe.recording_studio_ai.rb")
      File.write(path, <<~RUBY)
        class GuardSuffixProbe < ActiveRecord::Migration[8.1]
          def change; end
        end
      RUBY

      klass = FreshPostgresMigrationGuard.apply_migration_file(path, record_version: false)
      assert_equal GuardSuffixProbe, klass
    end
  end

  private

  def postgres_available?
    ActiveRecord::Base.connection.adapter_name.match?(/PostgreSQL/i)
  rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError, PG::ConnectionBad
    false
  end

  def run_scenario(scenario)
    script = Rails.root.join("test/support/fresh_postgres_migration_guard.rb").to_s
    stdout, status = Open3.capture2e(
      { "RAILS_ENV" => "test" },
      Gem.ruby, "-rbundler/setup", script, scenario,
      chdir: Rails.root.to_s
    )
    assert status.success?, stdout
    assert_includes stdout, "ok #{scenario}"
  end
end
