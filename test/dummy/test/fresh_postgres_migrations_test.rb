# frozen_string_literal: true

require "test_helper"
require "open3"

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
