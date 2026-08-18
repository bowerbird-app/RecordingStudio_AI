# frozen_string_literal: true

require "test_helper"

class ProviderRegistrationTest < RecordingStudioAI::Test::IsolatedCase
  class ProbeProvider < RecordingStudioAI::Providers::Base
    provider_key :glue_probe
  end

  def test_a_third_provider_registers_through_the_existing_api
    configuration = isolate_configuration!
    configuration.singleton_class.class_eval do
      attr_accessor :glue_probe_api_key, :glue_probe_client
    end

    provider = ProbeProvider.new(configuration: configuration)
    refute provider.configured?

    configuration.glue_probe_api_key = "probe-key"
    assert provider.configured?

    RecordingStudioAI.register_provider(:glue_probe, provider)

    assert_same provider, RecordingStudioAI.configuration.providers[:glue_probe]
    assert RecordingStudioAI.configuration.providers[:openai]
    assert RecordingStudioAI.configuration.providers[:gemini]
  end

  def test_injected_client_also_marks_a_provider_configured
    configuration = isolate_configuration!
    configuration.singleton_class.class_eval do
      attr_accessor :glue_probe_api_key, :glue_probe_client
    end
    client = Object.new
    configuration.glue_probe_client = client
    provider = ProbeProvider.new(configuration: configuration)

    assert provider.configured?
  end

  def test_base_subclasses_without_credential_accessors_stay_configured
    provider = ProbeProvider.new

    assert_nil provider.instance_variable_get(:@configuration)
    assert provider.configured?
  end

  def test_register_provider_still_requires_the_base_class
    isolate_configuration!

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.register_provider(:invalid, Object.new)
    end

    assert_equal "configuration", error.code
    assert_includes error.message, "Providers::Base"
  end

  def test_starter_example_shows_env_backed_credentials
    assert_includes RecordingStudioAI::Providers::StarterExample::CLASS_CODE, "provider_key :my_provider"
    assert_includes RecordingStudioAI::Providers::StarterExample::CLASS_CODE, "configuration_api_key"
    assert_includes RecordingStudioAI::Providers::StarterExample::INITIALIZER_CODE, 'ENV.fetch("MY_PROVIDER_API_KEY"'
    assert_includes RecordingStudioAI::Providers::StarterExample::INITIALIZER_CODE, "attr_accessor :my_provider_api_key"
    assert_includes RecordingStudioAI::Providers::StarterExample::INITIALIZER_CODE, "register_provider"
  end
end
