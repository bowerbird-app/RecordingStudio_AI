# frozen_string_literal: true

require "test_helper"
require "active_job"
require "action_controller"
require "active_support/core_ext/string/output_safety"

class SecurityHardeningTest < Minitest::Test
  def test_metadata_redacts_provider_style_secret_keys
    sanitized = RecordingStudioAI::Metadata.sanitize!(
      {
        openai_key: "sk-live",
        gemini_key: "ge-live",
        typesafe_key: "ts-live",
        private_key: "pk",
        access_key: "ak",
        safe: "ok"
      }
    )

    assert_equal "[REDACTED]", sanitized.fetch("openai_key")
    assert_equal "[REDACTED]", sanitized.fetch("gemini_key")
    assert_equal "[REDACTED]", sanitized.fetch("typesafe_key")
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

  def test_openai_webhook_signature_verifier_accepts_explicit_true
    with_openai_signature_outcome(true) do |context|
      assert RecordingStudioAI::Webhooks::OpenaiProvider.signature_verifier.call(context)
    end
  end

  def test_openai_webhook_signature_verifier_rejects_explicit_false
    with_openai_signature_outcome(false) do |context|
      refute RecordingStudioAI::Webhooks::OpenaiProvider.signature_verifier.call(context)
    end
  end

  def test_openai_webhook_signature_verifier_accepts_void_nil_success
    with_openai_signature_outcome(nil) do |context|
      assert RecordingStudioAI::Webhooks::OpenaiProvider.signature_verifier.call(context)
    end
  end

  def test_openai_webhook_signature_verifier_rejects_raised_verification_error
    error_class = if defined?(OpenAI::Errors::InvalidWebhookSignatureError)
                    OpenAI::Errors::InvalidWebhookSignatureError
                  else
                    Class.new(StandardError)
                  end

    with_openai_signature_outcome(->(*) { raise error_class, "secret-in-message" }) do |context|
      refute RecordingStudioAI::Webhooks::OpenaiProvider.signature_verifier.call(context)
    end
  end

  def test_host_sanitizer_raise_stores_nothing_and_logs_class_only
    original = RecordingStudioAI.configuration.response_sanitizer
    RecordingStudioAI.configuration.response_sanitizer = ->(*) { raise "secret-token-in-message" }
    logs = []
    logger = Object.new
    logger.define_singleton_method(:error) { |message| logs << message }
    previous_logger = Rails.logger
    Rails.logger = logger

    assert_nil RecordingStudioAI::Retention.sanitize("keep this text")
    assert_equal 1, logs.size
    assert_equal "RecordingStudioAI::Retention sanitizer raised RuntimeError", logs.first
    refute_includes logs.first, "secret-token-in-message"
  ensure
    RecordingStudioAI.configuration.response_sanitizer = original
    Rails.logger = previous_logger
  end

  def test_change_markup_escapes_interpolated_class_and_text
    require "recording_studio_ai/admin/runs_health"

    injected = { css_class: '"><img src=x onerror=alert(1)>', text: "<script>alert(1)</script>" }
    html = RecordingStudioAI::Admin::RunsHealth.stub(:headline_change, injected) do
      RecordingStudioAI::Admin::RunsHealth.change_markup(Object.new)
    end

    refute_includes html, "<script>"
    refute_includes html, "<img"
    assert_includes html, "&lt;script&gt;"
    assert html.html_safe?
  end

  def test_safe_rendered_html_escapes_raw_strings_and_keeps_safe_buffers
    require "recording_studio_ai/admin/recording_studio_ai_widgets"

    raw = AdminScreens::RecordingStudioAIWidgets.safe_rendered_html("<script>alert(1)</script>")
    safe = "<b>ok</b>".html_safe
    kept = AdminScreens::RecordingStudioAIWidgets.safe_rendered_html(safe)

    refute_includes raw, "<script>"
    assert_includes raw, "&lt;script&gt;"
    assert_equal "<b>ok</b>", kept
    assert kept.html_safe?
  end

  def test_admin_context_params_use_an_explicit_permit_list
    require "action_controller"

    source = File.read(
      File.expand_path("../app/controllers/recording_studio_ai/retained_responses_controller.rb", __dir__)
    )
    keys = %i[id authenticity_token utf8 _method commit]
    params = ActionController::Parameters.new(
      id: "12",
      authenticity_token: "token",
      utf8: "✓",
      evil: "<script>",
      controller: "recording_studio_ai/retained_responses",
      action: "show"
    )
    permitted = params.permit(*keys).to_h

    assert_includes source, "ADMIN_CONTEXT_PARAM_KEYS = %i[id authenticity_token utf8 _method commit]"
    assert_includes source, "params.permit(*ADMIN_CONTEXT_PARAM_KEYS)"
    refute_includes source, "to_unsafe_h"
    assert_equal "12", permitted["id"]
    assert_equal "token", permitted["authenticity_token"]
    refute permitted.key?("evil")
  end

  class AllowedSynchronizationJob < ActiveJob::Base; end

  def test_batch_synchronization_job_class_rejects_non_job_constantize
    configuration = RecordingStudioAI::Configuration.new
    configuration.batch_synchronization_job = "String"

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      configuration.batch_synchronization_job_class
    end

    assert_equal "configuration", error.code
    assert_match(/ActiveJob::Base/, error.message)
  end

  def test_batch_synchronization_job_class_accepts_active_job_subclass
    configuration = RecordingStudioAI::Configuration.new
    configuration.batch_synchronization_job = AllowedSynchronizationJob

    assert_equal AllowedSynchronizationJob, configuration.batch_synchronization_job_class
  end

  def with_openai_signature_outcome(outcome)
    original_secret = RecordingStudioAI.configuration.openai_webhook_secret
    original_client = RecordingStudioAI.configuration.openai_client
    RecordingStudioAI.configuration.openai_webhook_secret = "whsec_test"
    RecordingStudioAI.configuration.openai_client = Object.new.tap do |client|
      webhooks = Object.new
      if outcome.respond_to?(:call)
        webhooks.define_singleton_method(:verify_signature, &outcome)
      else
        webhooks.define_singleton_method(:verify_signature) { |*| outcome }
      end
      client.define_singleton_method(:webhooks) { webhooks }
    end

    yield Struct.new(:raw_payload, :headers).new("{}", {})
  ensure
    RecordingStudioAI.configuration.openai_webhook_secret = original_secret
    RecordingStudioAI.configuration.openai_client = original_client
  end
end
