# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    @original_openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
    @original_gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("GEMINI_API_KEY")
  end

  def teardown
    ENV["OPENAI_API_KEY"] = @original_openai_api_key
    ENV["GEMINI_API_KEY"] = @original_gemini_api_key
  end

  def test_v1_defaults_are_provider_independent
    configuration = RecordingStudioAI::Configuration.new

    assert_equal :medium, configuration.default_profile
    assert_equal false, configuration.retain_responses
    assert_equal 7.days, configuration.response_retention_period
    assert_equal 1_048_576, configuration.maximum_retained_response_size
    assert_equal 3, configuration.maximum_attempts
    assert_equal 1, configuration.maximum_retries_per_candidate
    assert_equal 1, configuration.maximum_provider_fallbacks
    assert_equal 5, configuration.maximum_custom_tool_rounds
    assert_nil configuration.openai_api_key
    assert_nil configuration.openai_client
    assert_nil configuration.gemini_api_key
    assert_nil configuration.gemini_client
    assert_equal 120, configuration.request_timeout
    refute_respond_to configuration, :provider
    refute_respond_to configuration, :default_provider
  end

  def test_provider_credentials_default_from_environment
    ENV["OPENAI_API_KEY"] = "openai-key"
    ENV["GEMINI_API_KEY"] = "gemini-key"

    configuration = RecordingStudioAI::Configuration.new

    assert_equal "openai-key", configuration.openai_api_key
    assert_equal "gemini-key", configuration.gemini_api_key
  end

  def test_configure_accepts_symmetric_provider_client_injection
    original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    RecordingStudioAI.instance_variable_set(:@configuration, RecordingStudioAI::Configuration.new)
    openai_client = Object.new
    gemini_client = Object.new

    RecordingStudioAI.configure do |config|
      config.openai_client = openai_client
      config.gemini_client = gemini_client
      config.request_timeout = 45
    end

    assert_same openai_client, RecordingStudioAI.configuration.openai_client
    assert_same gemini_client, RecordingStudioAI.configuration.gemini_client
    assert_equal 45, RecordingStudioAI.configuration.request_timeout
  ensure
    RecordingStudioAI.instance_variable_set(:@configuration, original_configuration)
  end

  def test_configure_without_a_block_is_safe
    assert_nil RecordingStudioAI.configure
    assert_instance_of RecordingStudioAI::Configuration, RecordingStudioAI.configuration
  end
end
