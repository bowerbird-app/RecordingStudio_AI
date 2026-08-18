# frozen_string_literal: true

require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/bytes"

module RecordingStudioAI
  class Configuration
    attr_accessor(
      :default_profile,
      :authorization_handler,
      :providers,
      :allowed_provider_overrides,
      :allowed_attachment_content_types,
      :attribution_validator,
      :batch_synchronization_job,
      :batch_synchronization_interval,
      :admin_actor_resolver,
      :admin_expensive_models,
      :admin_layout,
      :admin_slow_call_threshold_ms,
      :admin_warning_thresholds,
      :admin_visible_roots_resolver,
      :custom_tool_confirmation_handler,
      :custom_tool_timeout,
      :cost_catalogs,
      :discovery_enabled,
      :execution_history_retention_period,
      :gemini_api_key,
      :gemini_client,
      :maximum_attempts,
      :maximum_attachment_bytes,
      :maximum_attachment_count,
      :maximum_attachment_total_bytes,
      :maximum_custom_tool_rounds,
      :maximum_custom_tool_result_size,
      :maximum_provider_fallbacks,
      :maximum_profile_fallbacks,
      :maximum_retries_per_candidate,
      :maximum_retained_response_size,
      :instrumentation_enabled,
      :notification_namespace,
      :openai_api_key,
      :openai_client,
      :profiles,
      :profile_fallbacks,
      :request_timeout,
      :retry_backoff_base,
      :retry_backoff_max,
      :retry_jitter,
      :retry_random,
      :retry_sleeper,
      :response_sanitizer,
      :response_retention_period,
      :retain_responses,
      :stream_idle_timeout,
      :total_execution_timeout
    )

    def initialize
      @default_profile = :medium
      @authorization_handler = ->(**) { false }
      @providers = {}
      install_shipped_providers
      @allowed_provider_overrides = []
      @discovery_enabled = false
      @attribution_validator = method(:validate_recording_attribution!)
      @batch_synchronization_job = "RecordingStudioAI::BatchSynchronizationJob"
      @batch_synchronization_interval = 1.minute
      @admin_actor_resolver = nil
      @admin_expensive_models = []
      @admin_layout = nil
      @admin_slow_call_threshold_ms = 10_000
      @admin_warning_thresholds = {
        runs: 1_000,
        error_rate: 0.1,
        total_tokens: 1_000_000,
        spend_microunits: 100_000_000,
        average_latency_ms: 10_000,
        slow_calls: 1,
        retries: 10,
        fallbacks: 10,
        tool_calls: 25,
        maximum_tool_calls_per_run: 5,
        expensive_model_runs: 1,
        destructive_requests: 1,
        confirmation_rejections: 1,
        batch_failures: 1,
        batch_expirations: 1,
        provider_error_rate: 0.2
      }
      @admin_visible_roots_resolver = nil
      @allowed_attachment_content_types = %w[
        image/png
        image/jpeg
        image/gif
        image/webp
        application/pdf
        application/json
        text/plain
        text/csv
        text/markdown
      ]
      @custom_tool_confirmation_handler = ->(**) { false }
      @custom_tool_timeout = 30
      @cost_catalogs = {}
      @execution_history_retention_period = nil
      @gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)
      @gemini_client = nil
      @maximum_attempts = 3
      @maximum_attachment_bytes = 20.megabytes
      @maximum_attachment_count = 10
      @maximum_attachment_total_bytes = 50.megabytes
      @maximum_custom_tool_rounds = 5
      @maximum_custom_tool_result_size = 256.kilobytes
      @maximum_provider_fallbacks = 1
      @maximum_profile_fallbacks = 1
      @maximum_retries_per_candidate = 1
      @maximum_retained_response_size = 1.megabyte
      @instrumentation_enabled = true
      @notification_namespace = "recording_studio_ai"
      @openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
      @openai_client = nil
      @profiles = {
        low: [
          { provider: :openai, model: "gpt-5-mini" },
          { provider: :gemini, model: "gemini-2.5-flash" }
        ],
        medium: [
          { provider: :openai, model: "gpt-5" },
          { provider: :gemini, model: "gemini-2.5-pro" }
        ],
        high: [
          { provider: :openai, model: "gpt-5-pro" },
          { provider: :gemini, model: "gemini-2.5-pro" }
        ]
      }
      @profile_fallbacks = {}
      @request_timeout = 120
      @retry_backoff_base = 0.25
      @retry_backoff_max = 5.0
      @retry_jitter = 0.2
      @retry_random = -> { rand }
      @retry_sleeper = ->(seconds) { sleep(seconds) }
      @response_sanitizer = nil
      @response_retention_period = 7.days
      @retain_responses = false
      @stream_idle_timeout = 30
      @total_execution_timeout = 300
    end

    def validate!
      validate_integer!(:maximum_attempts, minimum: 1)
      %i[
        maximum_attachment_count maximum_attachment_bytes maximum_attachment_total_bytes
        maximum_custom_tool_rounds maximum_custom_tool_result_size maximum_provider_fallbacks
        maximum_profile_fallbacks maximum_retries_per_candidate maximum_retained_response_size
        admin_slow_call_threshold_ms
      ].each { |name| validate_integer!(name, minimum: 0) }
      %i[custom_tool_timeout request_timeout stream_idle_timeout total_execution_timeout retry_backoff_base
         retry_backoff_max].each { |name| validate_number!(name, minimum: 0) }
      validate_number!(:retry_jitter, minimum: 0, maximum: 1)
      if retry_backoff_max < retry_backoff_base
        invalid_configuration!("retry_backoff_max must be greater than or equal to retry_backoff_base")
      end
      invalid_configuration!("retry_random must respond to call") unless retry_random.respond_to?(:call)
      invalid_configuration!("retry_sleeper must respond to call") unless retry_sleeper.respond_to?(:call)
      if execution_history_retention_period &&
         (!execution_history_retention_period.respond_to?(:positive?) || !execution_history_retention_period.positive?)
        invalid_configuration!("execution_history_retention_period must be nil or a positive duration")
      end
      %i[batch_synchronization_interval response_retention_period].each do |name|
        value = public_send(name)
        invalid_configuration!("#{name} must be a positive duration") unless value.respond_to?(:positive?) && value.positive?
      end
      unless batch_synchronization_job.is_a?(String) || batch_synchronization_job.respond_to?(:perform_later)
        invalid_configuration!("batch_synchronization_job must respond to perform_later")
      end
      self
    end

    def batch_synchronization_job_class
      return batch_synchronization_job.constantize if batch_synchronization_job.is_a?(String)

      batch_synchronization_job
    end

    private

    def install_shipped_providers
      [
        RecordingStudioAI::Providers::OpenAI,
        RecordingStudioAI::Providers::Gemini
      ].each do |provider_class|
        store_provider(provider_class.provider_key, provider_class.new(configuration: self))
      end
    end

    def store_provider(key, provider)
      unless provider.is_a?(RecordingStudioAI::Providers::Base)
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "provider must inherit from RecordingStudioAI::Providers::Base",
          code: "configuration"
        )
      end

      @providers[key.to_sym] = provider
    end

    def validate_integer!(name, minimum:)
      value = public_send(name)
      return if value.is_a?(Integer) && value >= minimum

      invalid_configuration!("#{name} must be an Integer greater than or equal to #{minimum}")
    end

    def validate_number!(name, minimum:, maximum: nil)
      value = public_send(name)
      valid = value.is_a?(Numeric) && value.finite? && value >= minimum
      valid &&= value <= maximum if maximum
      return if valid

      range = maximum ? "between #{minimum} and #{maximum}" : "greater than or equal to #{minimum}"
      invalid_configuration!("#{name} must be a finite number #{range}")
    end

    def invalid_configuration!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "configuration")
    end

    def validate_recording_attribution!(root_recording:, context_recording:)
      recording_class = defined?(RecordingStudio::Recording) && RecordingStudio::Recording
      unless recording_class && root_recording.is_a?(recording_class) &&
             root_recording.parent_recording_id.nil? &&
             root_recording.root_recording_id == root_recording.id
        raise ArgumentError, "root_recording must be a Recording Studio root"
      end
      return if context_recording.nil?

      unless context_recording.is_a?(recording_class) &&
             context_recording.root_recording_id == root_recording.id
        raise ArgumentError, "context_recording must belong to root_recording"
      end
    end
  end
end
