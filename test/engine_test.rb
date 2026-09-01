# frozen_string_literal: true

require "test_helper"

class EngineTest < Minitest::Test
  def test_engine_is_isolated_under_recording_studio_ai
    assert RecordingStudioAI::Engine.isolated?
    assert_equal "recording_studio_ai", RecordingStudioAI::Engine.engine_name
  end

  def test_engine_recognizes_admin_run_show_route
    load RecordingStudioAI::Engine.root.join("config/routes.rb")

    assert_includes RecordingStudioAI::Engine.routes.routes.map(&:name), "admin_run"
    refute_includes RecordingStudioAI::Engine.routes.routes.map(&:name), "admin_runs"
    refute_includes RecordingStudioAI::Engine.routes.routes.map(&:name), "admin_batches"
    refute_includes RecordingStudioAI::Engine.routes.routes.map(&:name), "admin_custom_tools"
  end

  def test_recording_studio_dependency_is_loaded
    assert defined?(RecordingStudio)
    assert_operator RecordingStudio::VERSION, :>=, "4.2.0"
  end
end
