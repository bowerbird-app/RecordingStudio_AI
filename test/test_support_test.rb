# frozen_string_literal: true

require "test_helper"

class TestSupportIsolationTest < RecordingStudioAI::Test::IsolatedCase
  def test_isolate_configuration_swaps_a_fresh_instance
    original = RecordingStudioAI.configuration

    isolate_configuration!

    refute_same original, RecordingStudioAI.configuration
    assert_instance_of RecordingStudioAI::Configuration, RecordingStudioAI.configuration
  end
end

class TestSupportPersistenceTest < RecordingStudioAI::Test::PersistenceCase
  def test_core_schema_creates_host_and_engine_tables
    tables = ActiveRecord::Base.connection.tables

    assert_includes tables, "recording_studio_recordings"
    assert_includes tables, "recording_studio_ai_runs"
    refute_includes tables, "recording_studio_events"
    assert_operator create_recording_id, :>, 0
  end
end
