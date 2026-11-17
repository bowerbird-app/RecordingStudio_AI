# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class MissingMigrationsTest < Minitest::Test
  GEM_MIGRATIONS = RecordingStudioAI::Engine.root.join("db/migrate")
  HOSTED_AGENT = "allow_recording_studio_ai_hosted_agent_runs"
  INSTALL_COMMAND = "bin/rails recording_studio_ai:install:migrations"

  def setup
    @previous_env = Rails.env
    @previous_raise = RecordingStudioAI.configuration.raise_on_missing_migrations
  end

  def teardown
    Rails.env = @previous_env
    RecordingStudioAI.configuration.raise_on_missing_migrations = @previous_raise
  end

  def test_nothing_missing_when_every_name_is_copied
    with_migrations do |host, gem_directory|
      write_migration(gem_directory, "20261016120000_#{HOSTED_AGENT}.rb")
      write_migration(gem_directory, "20261112120000_refresh_recording_studio_ai_terminal_guards.rb")
      write_migration(host, "20270101010101_#{HOSTED_AGENT}.recording_studio_ai.rb")
      write_migration(host, "20270101010102_refresh_recording_studio_ai_terminal_guards.recording_studio_ai.rb")
      write_migration(host, "20200101_.rb")
      write_migration(host, "not-a-migration.rb")

      result = RecordingStudioAI::MissingMigrations.check(host_directory: host, gem_directory: gem_directory)

      refute result.missing?
      assert_empty result.missing
      assert_equal INSTALL_COMMAND, result.command
      assert_equal "Recording Studio AI migrations are installed.", result.message
    end
  end

  def test_reports_migrations_whose_names_are_absent
    with_migrations do |host, gem_directory|
      write_migration(gem_directory, "20261016120000_#{HOSTED_AGENT}.rb")
      write_migration(gem_directory, "20261112120000_refresh_recording_studio_ai_terminal_guards.rb")
      write_migration(host, "20270101010102_refresh_recording_studio_ai_terminal_guards.recording_studio_ai.rb")
      write_migration(host, "20270101010103_allow_recording_studio_ai_hosted_agent_runs_extra.rb")

      result = RecordingStudioAI::MissingMigrations.check(host_directory: host, gem_directory: gem_directory)

      assert_equal [HOSTED_AGENT], result.missing
      absent_host = RecordingStudioAI::MissingMigrations.check(
        host_directory: File.join(host, "missing"),
        gem_directory: gem_directory
      )
      assert_equal [HOSTED_AGENT, "refresh_recording_studio_ai_terminal_guards"], absent_host.missing
      assert_includes result.message, HOSTED_AGENT
      assert_includes result.message, INSTALL_COMMAND
      assert_includes result.message, "bin/rails db:migrate"
    end
  end

  def test_renamed_timestamp_and_unsuffixed_copies_count
    with_migrations do |host, gem_directory|
      write_migration(gem_directory, "20261016120000_#{HOSTED_AGENT}.rb")
      write_migration(gem_directory, "20260814130000_remove_cost_columns_from_recording_studio_ai.rb")
      write_migration(host, "20290115120000_#{HOSTED_AGENT}.recording_studio_ai.rb")
      write_migration(host, "20260814130000_remove_cost_columns_from_recording_studio_ai.rb")

      result = RecordingStudioAI::MissingMigrations.check(host_directory: host, gem_directory: gem_directory)

      assert_empty result.missing
    end
  end

  def test_real_gem_migrations_match_renamed_scope_copies
    Dir.mktmpdir do |empty_host|
      missing_when_absent = RecordingStudioAI::MissingMigrations.check(
        host_directory: empty_host,
        gem_directory: GEM_MIGRATIONS
      )
      assert_includes missing_when_absent.missing, HOSTED_AGENT

      Dir.mktmpdir do |host|
        missing_when_absent.missing.each_with_index do |name, index|
          write_migration(host, format("2099%010d_%s.recording_studio_ai.rb", index, name))
        end

        installed = RecordingStudioAI::MissingMigrations.check(host_directory: host, gem_directory: GEM_MIGRATIONS)
        assert_empty installed.missing

        File.delete(Dir.glob(File.join(host, "*#{HOSTED_AGENT}.recording_studio_ai.rb")).fetch(0))
        removed = RecordingStudioAI::MissingMigrations.check(host_directory: host, gem_directory: GEM_MIGRATIONS)
        assert_equal [HOSTED_AGENT], removed.missing
      end
    end
  end

  def test_boot_hook_is_skipped_outside_development_and_test
    %w[production staging].each do |env_name|
      app, callbacks = fake_app
      called = false
      Rails.env = env_name
      RecordingStudioAI::MissingMigrations.stub(:report, ->(**) { called = true }) do
        RecordingStudioAI::MissingMigrations.watch(app)
        callbacks.each(&:call)
      end

      assert_empty callbacks, env_name
      refute called, env_name
    end
  end

  def test_boot_hook_reports_in_development_and_test
    %w[development test].each do |env_name|
      app, callbacks = fake_app
      called = false
      Rails.env = env_name
      RecordingStudioAI::MissingMigrations.stub(:report, ->(**) { called = true }) do
        RecordingStudioAI::MissingMigrations.watch(app)
        callbacks.each(&:call)
      end

      assert_equal 1, callbacks.size, env_name
      assert called, env_name
    end
  end

  def test_engine_registers_the_boot_check
    names = RecordingStudioAI::Engine.initializers.map(&:name)
    assert_includes names, "recording_studio_ai.missing_migrations"
  end

  def test_flag_raises_instead_of_warning
    RecordingStudioAI.configuration.raise_on_missing_migrations = true

    with_migrations do |host, gem_directory|
      write_migration(gem_directory, "20261016120000_#{HOSTED_AGENT}.rb")

      error = assert_raises(RecordingStudioAI::MissingMigrations::Error) do
        capture_io do
          RecordingStudioAI::MissingMigrations.report(host_directory: host, gem_directory: gem_directory)
        end
      end

      assert_includes error.message, HOSTED_AGENT
      assert_includes error.message, INSTALL_COMMAND
    end
  end

  def test_report_warns_when_the_flag_is_off
    RecordingStudioAI.configuration.raise_on_missing_migrations = false

    with_migrations do |host, gem_directory|
      write_migration(gem_directory, "20261016120000_#{HOSTED_AGENT}.rb")
      write_migration(host, "20270101010101_#{HOSTED_AGENT}.recording_studio_ai.rb")

      _output, error_output = capture_io do
        result = RecordingStudioAI::MissingMigrations.report(host_directory: host, gem_directory: gem_directory)
        assert_empty result.missing
      end
      assert_equal "", error_output

      File.delete(Dir.glob(File.join(host, "*.rb")).fetch(0))
      _output, error_output = capture_io do
        result = RecordingStudioAI::MissingMigrations.report(host_directory: host, gem_directory: gem_directory)
        assert_equal [HOSTED_AGENT], result.missing
      end
      assert_includes error_output, HOSTED_AGENT
      assert_includes error_output, INSTALL_COMMAND
    end
  end

  private

  def with_migrations
    Dir.mktmpdir do |host|
      Dir.mktmpdir do |gem_directory|
        yield host, gem_directory
      end
    end
  end

  def write_migration(directory, filename)
    File.write(File.join(directory, filename), "# migration\n")
  end

  def fake_app
    callbacks = []
    config = Object.new
    config.define_singleton_method(:after_initialize) { |&block| callbacks << block }
    [Struct.new(:config).new(config), callbacks]
  end
end
