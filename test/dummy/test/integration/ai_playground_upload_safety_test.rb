# frozen_string_literal: true

require "test_helper"

class AIPlaygroundUploadSafetyTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include AccessibleTestHelpers

  setup do
    @previous_bytes = RecordingStudioAI.configuration.maximum_attachment_bytes
    @previous_total = RecordingStudioAI.configuration.maximum_attachment_total_bytes
    RecordingStudioAI.configuration.maximum_attachment_bytes = 16
    RecordingStudioAI.configuration.maximum_attachment_total_bytes = 16
  end

  teardown do
    RecordingStudioAI.configuration.maximum_attachment_bytes = @previous_bytes
    RecordingStudioAI.configuration.maximum_attachment_total_bytes = @previous_total
  end

  test "oversized attachment is rejected before bytes are read into memory" do
    sign_in_playground_editor!

    Tempfile.create(["oversized", ".txt"]) do |file|
      file.write("this payload is longer than sixteen bytes")
      file.rewind

      post "/ai_playground", params: {
        ai_playground: {
          mode: "generate",
          prompt_key: "osaka_weather:1",
          profile: "medium",
          provider: "auto",
          attachment: Rack::Test::UploadedFile.new(file.path, "text/plain")
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match(/too big/i, response.body)
    refute_match(/ContractValidationError/i, response.body)
  end

  test "capped read rejects when declared size is small but bytes exceed the limit" do
    controller = AIPlaygroundController.new
    controller.set_request!(ActionDispatch::Request.empty)
    io = StringIO.new("x" * 100)
    upload = Object.new
    upload.define_singleton_method(:size) { 1 }
    upload.define_singleton_method(:read) { |*args| io.read(*args) }
    upload.define_singleton_method(:rewind) { io.rewind }
    upload.define_singleton_method(:tempfile) { nil }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      controller.send(:read_capped_upload!, upload)
    end
    assert_match(/too big/i, error.message)
  end

  test "unexpected generate failures do not leak exception class or internals" do
    sign_in_playground_editor!
    singleton = RecordingStudioAI.singleton_class
    original = singleton.instance_method(:generate)
    singleton.define_method(:generate) do |**|
      raise RuntimeError, "secret token xyz"
    end

    post "/ai_playground", params: {
      ai_playground: {
        mode: "generate",
        prompt_key: "osaka_weather:1",
        profile: "medium",
        provider: "auto"
      }
    }

    assert_response :unprocessable_entity
    assert_match(/try again in a moment/i, response.body)
    refute_match(/secret token xyz/i, response.body)
    refute_match(/RuntimeError/i, response.body)
  ensure
    RecordingStudioAI.singleton_class.define_method(:generate, original) if original
  end

  private

  def sign_in_playground_editor!
    user = User.create!(email: "playground-upload-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Upload playground workspace")
    root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root, actor: user, role: :edit)
    sign_in user
    switch_to_root!(root)
  end
end
