# frozen_string_literal: true

require "test_helper"
require File.expand_path(
  "../app/controllers/recording_studio_ai/admin/recording_studio_admin_authorization",
  __dir__
)

class AdminRecordingStudioAdminAuthorizationTest < Minitest::Test
  def test_gate_is_unavailable_without_recording_studio_admin
    refute RecordingStudioAI::Admin::RecordingStudioAdminAuthorization.available?
  end
end
