# frozen_string_literal: true

require "test_helper"

class SecurityHardeningTest < Minitest::Test
  def test_metadata_redacts_provider_style_secret_keys
    sanitized = RecordingStudioAI::Metadata.sanitize!(
      {
        openai_key: "sk-live",
        gemini_key: "ge-live",
        private_key: "pk",
        access_key: "ak",
        safe: "ok"
      }
    )

    assert_equal "[REDACTED]", sanitized.fetch("openai_key")
    assert_equal "[REDACTED]", sanitized.fetch("gemini_key")
    assert_equal "[REDACTED]", sanitized.fetch("private_key")
    assert_equal "[REDACTED]", sanitized.fetch("access_key")
    assert_equal "ok", sanitized.fetch("safe")
  end

  def test_tool_call_rejects_oversized_arguments
    original = RecordingStudioAI.configuration.maximum_custom_tool_arguments_size
    RecordingStudioAI.configuration.maximum_custom_tool_arguments_size = 32

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Providers::ToolCall.new(
        provider_tool_call_id: "call_1",
        key: "lookup_project",
        arguments: { "blob" => "x" * 64 }
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/maximum_custom_tool_arguments_size/, error.message)
  ensure
    RecordingStudioAI.configuration.maximum_custom_tool_arguments_size = original
  end

  def test_openai_webhook_signature_verifier_rejects_explicit_false
    original_secret = RecordingStudioAI.configuration.openai_webhook_secret
    original_client = RecordingStudioAI.configuration.openai_client
    RecordingStudioAI.configuration.openai_webhook_secret = "whsec_test"
    RecordingStudioAI.configuration.openai_client = Object.new.tap do |client|
      webhooks = Object.new
      webhooks.define_singleton_method(:verify_signature) { |*| false }
      client.define_singleton_method(:webhooks) { webhooks }
    end

    context = Struct.new(:raw_payload, :headers).new("{}", {})
    refute RecordingStudioAI::Webhooks::OpenaiProvider.signature_verifier.call(context)
  ensure
    RecordingStudioAI.configuration.openai_webhook_secret = original_secret
    RecordingStudioAI.configuration.openai_client = original_client
  end
end
