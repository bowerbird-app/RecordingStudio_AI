# frozen_string_literal: true

require "test_helper"

class EngineTest < Minitest::Test
  def test_engine_is_isolated_under_recording_studio_ai
    assert RecordingStudioAI::Engine.isolated?
    assert_equal "recording_studio_ai", RecordingStudioAI::Engine.engine_name
  end

  def test_engine_recognizes_retained_response_route
    load RecordingStudioAI::Engine.root.join("config/routes.rb")

    names = RecordingStudioAI::Engine.routes.routes.map(&:name)
    assert_includes names, "retained_response"
    refute_includes names, "admin_runs"
    refute(RecordingStudioAI::Engine.routes.routes.any? { |route| route.path.spec.to_s.include?("/admin") })
  end

  def test_recording_studio_dependency_is_loaded
    assert defined?(RecordingStudio)
    assert_operator RecordingStudio::VERSION, :>=, "4.2.0"
  end
end
