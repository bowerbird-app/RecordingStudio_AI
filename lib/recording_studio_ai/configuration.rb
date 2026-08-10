# frozen_string_literal: true

module RecordingStudioAI
  class Configuration
    attr_accessor(
      :default_profile,
      :gemini_api_key,
      :gemini_client,
      :maximum_attempts,
      :maximum_custom_tool_rounds,
      :maximum_provider_fallbacks,
      :maximum_retries_per_candidate,
      :maximum_retained_response_size,
      :openai_api_key,
      :openai_client,
      :request_timeout,
      :response_retention_period,
      :retain_responses
    )

    def initialize
      @default_profile = :medium
      @gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)
      @gemini_client = nil
      @maximum_attempts = 3
      @maximum_custom_tool_rounds = 5
      @maximum_provider_fallbacks = 1
      @maximum_retries_per_candidate = 1
      @maximum_retained_response_size = 1.megabyte
      @openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
      @openai_client = nil
      @request_timeout = 120
      @response_retention_period = 7.days
      @retain_responses = false
    end
  end
end
