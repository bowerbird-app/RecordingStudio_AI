# frozen_string_literal: true

require "test_helper"

class AdminRecordingStudioAdminAuthorizationTest < Minitest::Test
  def test_gate_is_unavailable_without_recording_studio_admin
    refute RecordingStudioAI::Admin::RecordingStudioAdminAuthorization.available?
  end
end
