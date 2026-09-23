# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  CREDENTIAL_ENV_KEYS = %w[OPENAI_API_KEY GEMINI_API_KEY TYPESAFE_API_KEY].freeze

  def setup
    CREDENTIAL_ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def teardown
    CREDENTIAL_ENV_KEYS.each { |key| ENV.delete(key) }
  end

  def test_v1_defaults_are_provider_independent
    configuration = RecordingStudioAI::Configuration.new

    assert_equal :medium, configuration.default_profile
    assert_equal false, configuration.retain_responses
    assert_equal 7.days, configuration.response_retention_period
    assert_equal 1_048_576, configuration.maximum_retained_response_size
    assert_nil configuration.response_sanitizer
    assert configuration.instrumentation_enabled
    assert_equal "recording_studio_ai", configuration.notification_namespace
    refute_respond_to configuration, :admin_actor_resolver
    refute_respond_to configuration, :admin_authenticate
    refute_respond_to configuration, :admin_visible_roots_resolver
    refute_respond_to configuration, :admin_layout
    assert_equal 0.1, configuration.admin_warning_thresholds[:error_rate]
    assert_equal 100_000_000, configuration.admin_warning_thresholds[:spend_microunits]
    assert_equal 3, configuration.maximum_attempts
    assert_equal 20, configuration.maximum_decision_questions
    assert_equal 60_000, configuration.maximum_decision_state_characters
    assert_equal 4_000, configuration.maximum_decision_text_characters
    assert_equal 80_000, configuration.maximum_decision_characters
    assert_equal 10, configuration.maximum_attachment_count
    assert_equal 20.megabytes, configuration.maximum_attachment_bytes
    assert_equal 50.megabytes, configuration.maximum_attachment_total_bytes
    assert_equal 1, configuration.maximum_retries_per_candidate
    assert_equal 1, configuration.maximum_provider_fallbacks
    assert_equal 1, configuration.maximum_profile_fallbacks
    assert_empty configuration.profile_fallbacks
    assert_empty configuration.model_fallbacks
    assert_equal 5, configuration.maximum_custom_tool_rounds
    assert_equal 30, configuration.custom_tool_timeout
    assert_equal 256.kilobytes, configuration.maximum_custom_tool_result_size
    assert_equal 64.kilobytes, configuration.maximum_custom_tool_arguments_size
    assert_empty configuration.cost_catalogs
    assert_equal "RecordingStudioAI::BatchSynchronizationJob", configuration.batch_synchronization_job
    assert_equal 1.minute, configuration.batch_synchronization_interval
    assert_nil configuration.openai_webhook_secret
    assert_nil configuration.webhook_batch_initiator
    assert_equal 300, configuration.total_execution_timeout
    refute configuration.custom_tool_confirmation_handler.call
    assert_nil configuration.openai_api_key
    assert_nil configuration.openai_client
    assert_nil configuration.gemini_api_key
    assert_nil configuration.gemini_client
    assert_nil configuration.typesafe_api_key
    assert_nil configuration.typesafe_client
    assert_equal 120, configuration.request_timeout
    assert_raises(ArgumentError) do
      configuration.attribution_validator.call(root_recording: Object.new, context_recording: nil)
    end
    refute_respond_to configuration, :provider
    refute_respond_to configuration, :default_provider
    assert_equal %i[gemini openai typesafe], configuration.providers.keys.sort
    assert_instance_of RecordingStudioAI::Providers::OpenAI, configuration.providers[:openai]
    assert_instance_of RecordingStudioAI::Providers::Gemini, configuration.providers[:gemini]
    assert_instance_of RecordingStudioAI::Providers::TypeSafe, configuration.providers[:typesafe]
    assert_equal :openai, configuration.providers[:openai].class.provider_key
    assert_equal :gemini, configuration.providers[:gemini].class.provider_key
    assert_equal :typesafe, configuration.providers[:typesafe].class.provider_key
  end

  def test_default_profiles_append_the_decision_candidate_to_every_tier
    configuration = RecordingStudioAI::Configuration.new

    %i[low medium high].each do |profile|
      assert_equal(
        { provider: :typesafe, model: "jev-latest" },
        configuration.profiles.fetch(profile).last,
        "#{profile} must end with the decision candidate"
      )
    end
    low_models = configuration.profiles.fetch(:low).map { |entry| entry.fetch(:model) }

    assert_equal ["gpt-5-mini", "gemini-2.5-flash", "jev-latest"], low_models
  end

  def test_provider_credentials_default_from_environment
    ENV["OPENAI_API_KEY"] = "openai-key"
    ENV["GEMINI_API_KEY"] = "gemini-key"
    ENV["TYPESAFE_API_KEY"] = "typesafe-key"

    configuration = RecordingStudioAI::Configuration.new

    assert_equal "openai-key", configuration.openai_api_key
    assert_equal "gemini-key", configuration.gemini_api_key
    assert_equal "typesafe-key", configuration.typesafe_api_key
  end

  def test_authorization_fails_closed_until_the_host_configures_a_handler
    configuration = RecordingStudioAI::Configuration.new

    refute configuration.authorization_handler.call(
      action: "recording_studio_ai.execute",
      attribution: nil,
      context: {}
    )
  end

  def test_configure_accepts_symmetric_provider_client_injection
    original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    RecordingStudioAI.instance_variable_set(:@configuration, RecordingStudioAI::Configuration.new)
    openai_client = Object.new
    gemini_client = Object.new
    typesafe_client = Object.new

    RecordingStudioAI.configure do |config|
      config.openai_client = openai_client
      config.gemini_client = gemini_client
      config.typesafe_client = typesafe_client
      config.request_timeout = 45
    end

    assert_same openai_client, RecordingStudioAI.configuration.openai_client
    assert_same gemini_client, RecordingStudioAI.configuration.gemini_client
    assert_same typesafe_client, RecordingStudioAI.configuration.typesafe_client
    assert_equal 45, RecordingStudioAI.configuration.request_timeout
  ensure
    RecordingStudioAI.instance_variable_set(:@configuration, original_configuration)
  end

  def test_configure_without_a_block_is_safe
    assert_nil RecordingStudioAI.configure
    assert_instance_of RecordingStudioAI::Configuration, RecordingStudioAI.configuration
  end

  def test_execution_bounds_reject_invalid_configuration
    configuration = RecordingStudioAI::Configuration.new
    configuration.maximum_attempts = 0

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { configuration.validate! }

    assert_equal "configuration", error.code
    assert_includes error.message, "maximum_attempts"

    configuration = RecordingStudioAI::Configuration.new
    configuration.maximum_decision_questions = 0
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { configuration.validate! }
    assert_includes error.message, "maximum_decision_questions"

    configuration = RecordingStudioAI::Configuration.new
    configuration.maximum_decision_characters = configuration.maximum_decision_state_characters - 1
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { configuration.validate! }
    assert_includes error.message, "maximum_decision_characters"
  end
end
