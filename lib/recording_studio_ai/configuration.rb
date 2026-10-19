# frozen_string_literal: true

require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/bytes"

module RecordingStudioAI
  class Configuration
    attr_accessor(
      :default_profile,
      :stuck_run_threshold,
      :authorization_handler,
      :providers,
      :allowed_provider_overrides,
      :allowed_attachment_content_types,
      :attribution_validator,
      :batch_synchronization_job,
      :batch_synchronization_interval,
      :admin_expensive_models,
      :admin_slow_call_threshold_ms,
      :admin_warning_thresholds,
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
      :maximum_custom_tool_arguments_size,
      :maximum_custom_tool_result_size,
      :maximum_provider_fallbacks,
      :maximum_profile_fallbacks,
      :maximum_retries_per_candidate,
      :maximum_retained_response_size,
      :maximum_decision_questions,
      :maximum_decision_state_characters,
      :maximum_decision_text_characters,
      :maximum_decision_characters,
      :instrumentation_enabled,
      :notification_namespace,
      :openai_api_key,
      :openai_client,
      :openai_webhook_secret,
      :webhook_batch_initiator,
      :profiles,
      :profile_fallbacks,
      :model_fallbacks,
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
      :total_execution_timeout,
      :typesafe_api_key,
      :typesafe_client,
      :usage_handler,
      :usage_key_resolver
    )

    def initialize
      @default_profile = :medium
      @stuck_run_threshold = 15.minutes
      @authorization_handler = ->(**) { false }
      @usage_handler = nil
      @usage_key_resolver = nil
      @providers = {}
      install_shipped_providers
      @allowed_provider_overrides = []
      @discovery_enabled = false
      @attribution_validator = method(:validate_recording_attribution!)
      @batch_synchronization_job = "RecordingStudioAI::BatchSynchronizationJob"
      @batch_synchronization_interval = 1.minute
      @admin_expensive_models = []
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
      @maximum_custom_tool_arguments_size = 64.kilobytes
      @maximum_custom_tool_result_size = 256.kilobytes
      @maximum_provider_fallbacks = 1
      @maximum_profile_fallbacks = 1
      @maximum_retries_per_candidate = 1
      @maximum_retained_response_size = 1.megabyte
      @maximum_decision_questions = Decisions::MAXIMUM_QUESTIONS
      @maximum_decision_state_characters = Decisions::MAXIMUM_STATE_CHARACTERS
      @maximum_decision_text_characters = Decisions::MAXIMUM_TEXT_CHARACTERS
      @maximum_decision_characters = Decisions::MAXIMUM_DECISION_CHARACTERS
      @instrumentation_enabled = true
      @notification_namespace = "recording_studio_ai"
      @openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
      @openai_client = nil
      @openai_webhook_secret = ENV.fetch("OPENAI_WEBHOOK_SECRET", nil)
      @hosted_agent_backend = :agents_beta
      @hosted_agent_mcp_servers = []
      # Returns the initiator used when refresh_batch_from_webhook omits initiator:.
      # Example: ->(root_recording:, **) { SystemActor.instance }
      @webhook_batch_initiator = nil
      @profiles = {
        low: [
          { provider: :openai, model: "gpt-5-mini" },
          { provider: :gemini, model: "gemini-2.5-flash" },
          { provider: :openai, model: "gpt-6-astra" },
          { provider: :typesafe, model: "jev-latest" }
        ],
        medium: [
          { provider: :openai, model: "gpt-5" },
          { provider: :gemini, model: "gemini-2.5-pro" },
          { provider: :openai, model: "gpt-6-astra" },
          { provider: :typesafe, model: "jev-latest" }
        ],
        high: [
          { provider: :openai, model: "gpt-5-pro" },
          { provider: :gemini, model: "gemini-2.5-pro" },
          { provider: :openai, model: "gpt-6-astra" },
          { provider: :typesafe, model: "jev-latest" }
        ]
      }
      @profile_fallbacks = {}
      @model_fallbacks = {}
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
      @typesafe_api_key = ENV.fetch("TYPESAFE_API_KEY", nil)
      @typesafe_client = nil
    end

    def validate!
      validate_integer!(:maximum_attempts, minimum: 1)
      %i[
        maximum_decision_questions maximum_decision_state_characters
        maximum_decision_text_characters maximum_decision_characters
      ].each { |name| validate_integer!(name, minimum: 1) }
      if maximum_decision_characters < maximum_decision_state_characters
        invalid_configuration!(
          "maximum_decision_characters must be at least maximum_decision_state_characters"
        )
      end
      if maximum_decision_characters < maximum_decision_text_characters
        invalid_configuration!(
          "maximum_decision_characters must be at least maximum_decision_text_characters"
        )
      end
      %i[
        maximum_attachment_count maximum_attachment_bytes maximum_attachment_total_bytes
        maximum_custom_tool_rounds maximum_custom_tool_arguments_size maximum_custom_tool_result_size maximum_provider_fallbacks
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
      if !webhook_batch_initiator.nil? && !webhook_batch_initiator.respond_to?(:call)
        invalid_configuration!("webhook_batch_initiator must be nil or respond to call")
      end
      validate_usage_meter!
      self.hosted_agent_backend = hosted_agent_backend
      self.hosted_agent_mcp_servers = hosted_agent_mcp_servers
      normalize_model_fallbacks!
      self
    end

    attr_reader :hosted_agent_backend, :hosted_agent_mcp_servers

    SECRET_INSPECT_IVARS = %i[
      @openai_api_key @gemini_api_key @typesafe_api_key @openai_webhook_secret
    ].freeze

    def hosted_agent_backend=(value)
      @hosted_agent_backend = normalize_hosted_backend!(value)
    end

    def hosted_agent_mcp_servers=(value)
      @hosted_agent_mcp_servers = normalize_mcp_servers!(value)
    end

    def inspect
      parts = instance_variables.sort.map { |name| "#{name}=#{inspected_configuration_value(name)}" }
      "#<#{self.class.name} #{parts.join(' ')}>"
    end

    def to_s
      inspect
    end

    def model_fallbacks_for(provider, model)
      Array(@model_fallbacks[[provider.to_sym, model.to_s]])
    end

    def batch_synchronization_job_class
      return batch_synchronization_job.constantize if batch_synchronization_job.is_a?(String)

      batch_synchronization_job
    end

    private

    def normalize_model_fallbacks!
      raw = @model_fallbacks || {}
      invalid_configuration!("model_fallbacks must be a Hash") unless raw.is_a?(Hash)

      normalized = {}
      raw.each do |key, entries|
        provider, model = normalize_model_fallback_key!(key)
        list = begin
          RecordingStudioAI::FallbackEntries.normalize_list!(entries, path: "model_fallbacks[#{provider}/#{model}]")
        rescue RecordingStudioAI::Errors::ContractValidationError => e
          invalid_configuration!(e.message)
        end
        normalized[[provider, model]] = list
      end
      @model_fallbacks = normalized
    end

    def normalize_model_fallback_key!(key)
      case key
      when Array
        invalid_configuration!("model_fallbacks keys must be [provider, model]") unless key.length == 2
        provider, model = key
      when String
        provider, model = key.split("/", 2)
        invalid_configuration!("model_fallbacks string keys must look like provider/model") if model.nil? || model.empty?
      else
        invalid_configuration!("model_fallbacks keys must be [provider, model] or \"provider/model\"")
      end

      provider = provider.to_sym
      model = model.to_s.strip
      invalid_configuration!("model_fallbacks provider is required") if provider.to_s.empty?
      invalid_configuration!("model_fallbacks model is required") if model.empty?
      [provider, model]
    end

    def install_shipped_providers
      [
        RecordingStudioAI::Providers::OpenAI,
        RecordingStudioAI::Providers::Gemini,
        RecordingStudioAI::Providers::TypeSafe
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

    def validate_usage_meter!
      if present_but_not_callable?(usage_handler)
        invalid_configuration!("usage_handler must respond to call")
      end
      if present_but_not_callable?(usage_key_resolver)
        invalid_configuration!("usage_key_resolver must respond to call")
      end
      return if usage_handler.nil? || usage_key_resolver.respond_to?(:call)

      invalid_configuration!("usage_handler requires a usage_key_resolver that responds to call")
    end

    def present_but_not_callable?(value)
      !value.nil? && !value.respond_to?(:call)
    end

    def normalize_hosted_backend!(value)
      backend = value.to_sym
      return backend if %i[agents_beta responses].include?(backend)

      invalid_configuration!("hosted_agent_backend must be :agents_beta or :responses")
    end

    def normalize_mcp_servers!(value)
      invalid_configuration!("hosted_agent_mcp_servers must be an Array") unless value.is_a?(Array)

      labels = []
      value.map { |server| normalize_mcp_server!(server, labels) }
    end

    def normalize_mcp_server!(server, labels)
      invalid_configuration!("hosted agent MCP server must be a Hash") unless server.is_a?(Hash)

      raw = server.to_h.transform_keys(&:to_sym)
      allowed = %i[server_url server_label authorization headers allowed_tools require_approval]
      unknown = raw.keys - allowed
      if unknown.any?
        invalid_configuration!("unknown hosted agent MCP keys: #{unknown.join(', ')}")
      end
      url = raw[:server_url].to_s.strip
      invalid_configuration!("hosted agent MCP server_url is required") if url.empty?
      label = raw[:server_label].to_s.strip.presence || derived_mcp_label(url)
      unless label.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        invalid_configuration!(
          "hosted agent MCP server label must use letters, numbers, underscores, or hyphens " \
          "(got #{label.inspect})"
        )
      end
      if labels.include?(label)
        invalid_configuration!("hosted agent MCP server label #{label} is already used")
      end
      labels << label
      approval = (raw[:require_approval].presence || "always").to_s
      unless %w[never always].include?(approval)
        invalid_configuration!("hosted agent MCP require_approval must be never or always")
      end
      headers = raw[:headers]
      if headers && !headers.is_a?(Hash)
        invalid_configuration!("hosted agent MCP headers must be a Hash")
      end
      McpServer[
        server_url: url, server_label: label, authorization: raw[:authorization]&.to_s.presence,
        headers: headers&.transform_keys(&:to_s),
        allowed_tools: raw[:allowed_tools].nil? ? nil : Array(raw[:allowed_tools]).map(&:to_s),
        require_approval: approval
      ]
    end

    # The reader returns these hashes. inspect and to_s hide the bearer token
    # and header values; callers still read the real authorization.
    class McpServer < Hash
      def inspect
        redacted = {}
        each { |key, value| redacted[key] = value }
        redacted[:authorization] = "[REDACTED]" if self[:authorization]
        redacted[:headers] = "[REDACTED]" if self[:headers]
        redacted.inspect
      end

      alias to_s inspect
    end

    def derived_mcp_label(url)
      host = url[%r{\A[a-z][a-z0-9+.-]*://([^/:?#]+)}i, 1].to_s.downcase.tr(".", "-")
      invalid_configuration!("hosted agent MCP server_url must include a host") if host.empty?

      host
    end

    def inspected_configuration_value(name)
      value = instance_variable_get(name)
      return "[REDACTED]".inspect if redact_inspect?(name, value)
      return inspected_mcp_servers(value).inspect if name == :@hosted_agent_mcp_servers

      value.inspect
    end

    def redact_inspect?(name, value)
      SECRET_INSPECT_IVARS.include?(name) && !value.nil? && !value.to_s.empty?
    end

    def inspected_mcp_servers(servers)
      Array(servers).map do |server|
        next server unless server.is_a?(Hash)

        redacted = server.dup
        redacted[:authorization] = "[REDACTED]" if redacted[:authorization]
        redacted[:headers] = "[REDACTED]" if redacted[:headers]
        redacted
      end
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
