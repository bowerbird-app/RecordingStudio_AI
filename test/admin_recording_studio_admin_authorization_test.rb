# frozen_string_literal: true

require "test_helper"

class AdminRecordingStudioAdminAuthorizationTest < Minitest::Test
  def test_gate_is_unavailable_without_recording_studio_admin
    assert RecordingStudioAI.const_defined?(:RecordingStudioAdminAuthorization)
    refute RecordingStudioAI::RecordingStudioAdminAuthorization.available?
  end
end
