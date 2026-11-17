# frozen_string_literal: true

require "test_helper"
require "rake"

class MissingMigrationsTest < ActiveSupport::TestCase
  test "dummy host has every recording studio ai migration" do
    result = RecordingStudioAI::MissingMigrations.check

    assert_empty result.missing
    assert_equal "bin/rails recording_studio_ai:install:migrations", result.command
    assert_equal "Recording Studio AI migrations are installed.", result.message
  end

  test "check_migrations prints that the copies are installed" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("recording_studio_ai:check_migrations")
    Rake::Task["recording_studio_ai:check_migrations"].reenable

    output, error_output = capture_io do
      Rake::Task["recording_studio_ai:check_migrations"].invoke
    end

    assert_includes output, "Recording Studio AI migrations are installed."
    assert_equal "", error_output
  end
end
