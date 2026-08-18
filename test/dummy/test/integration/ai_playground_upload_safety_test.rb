# frozen_string_literal: true

require "test_helper"

class AIPlaygroundUploadSafetyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include AccessibleTestHelpers

  test "oversized attachment is rejected before bytes are read into memory" do
    user = User.create!(email: "playground-upload-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Upload playground workspace")
    root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root, actor: user, role: :edit)
    sign_in user
    switch_to_root!(root)

    previous_limit = RecordingStudioAI.configuration.maximum_attachment_bytes
    RecordingStudioAI.configuration.maximum_attachment_bytes = 16

    Tempfile.create(["oversized", ".txt"]) do |file|
      file.write("this payload is longer than sixteen bytes")
      file.rewind

      post "/ai_playground", params: {
        ai_playground: {
          mode: "generate",
          prompt: "hello",
          profile: "medium",
          provider: "auto",
          attachment: Rack::Test::UploadedFile.new(file.path, "text/plain")
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/too big/i, response.body)
  ensure
    RecordingStudioAI.configuration.maximum_attachment_bytes = previous_limit if previous_limit
  end
end
