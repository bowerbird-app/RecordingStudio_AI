# frozen_string_literal: true

require "test_helper"

class EngineTest < Minitest::Test
  def test_engine_is_isolated_under_recording_studio_ai
    assert RecordingStudioAI::Engine.isolated?
    assert_equal "recording_studio_ai", RecordingStudioAI::Engine.engine_name
  end

  def test_engine_has_no_phase_one_routes
    assert_empty RecordingStudioAI::Engine.routes.routes
  end

  def test_recording_studio_dependency_is_loaded
    assert defined?(RecordingStudio)
    assert_operator RecordingStudio::VERSION, :>=, "3.0.0"
  end
end
