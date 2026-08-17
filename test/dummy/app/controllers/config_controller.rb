# frozen_string_literal: true

class ConfigController < ApplicationController
  CONFIG_OPTIONS = [
    {
      key: "openai_api_key",
      required: "Conditional",
      accepted_values: "String or nil",
      explanation: "API key for OpenAI provider. Required when OpenAI-backed profiles or overrides are used."
    },
    {
      key: "gemini_api_key",
      required: "Conditional",
      accepted_values: "String or nil",
      explanation: "API key for Gemini provider. Required when Gemini-backed profiles or overrides are used."
    },
    {
      key: "openai_client",
      required: "No",
      accepted_values: "Custom client object or nil",
      explanation: "Inject a custom OpenAI transport/client implementation."
    },
    {
      key: "gemini_client",
      required: "No",
      accepted_values: "Custom client object or nil",
      explanation: "Inject a custom Gemini transport/client implementation."
    },
    {
      key: "default_profile",
      required: "Yes",
      accepted_values: "Symbol profile key (for example :low, :medium, :high)",
      explanation: "Default profile used when requests do not specify a profile."
    },
    {
      key: "profiles",
      required: "Yes",
      accepted_values: "Hash of profile keys to ordered { provider:, model: } candidates",
      explanation: "Core model routing map used by generate, stream, and batch APIs. Reference models by their provider API model string; capabilities/parameters/tools/modalities come from the model registry (RecordingStudioAI.models)."
    },
    {
      key: "allowed_provider_overrides",
      required: "No",
      accepted_values: "Array of provider symbols",
      explanation: "Allow explicit provider overrides from callers. Keep empty to force profile-driven routing."
    },
    {
      key: "providers",
      required: "No",
      accepted_values: "Hash keyed by provider symbol => provider object",
      explanation: "Provider registry. Override only for custom providers or tests."
    },
    {
      key: "discovery_enabled",
      required: "No",
      accepted_values: "Boolean",
      explanation: "When true, RecordingStudioAI.configure calls discover_providers! to auto-register provider classes found under lib/recording_studio_ai/providers/*.rb."
    },
    {
      key: "authorization_handler",
      required: "Yes",
      accepted_values: "Callable receiving keyword args",
      explanation: "Authorization gate for AI actions. Should return true/false."
    },
    {
      key: "attribution_validator",
      required: "Yes",
      accepted_values: "Callable(root_recording:, context_recording:)",
      explanation: "Validates recording attribution boundaries before execution."
    },
    {
      key: "cost_catalogs",
      required: "No",
      accepted_values: "Hash",
      explanation: "Per-model pricing metadata for spend reporting and estimation."
    },
    {
      key: "batch_synchronization_job",
      required: "No",
      accepted_values: "ActiveJob class or class-name String",
      explanation: "Asynchronous batch polling job. Defaults to RecordingStudioAI::BatchSynchronizationJob and uses Sidekiq when configured as the ActiveJob adapter."
    },
    {
      key: "batch_synchronization_interval",
      required: "Yes",
      accepted_values: "Positive ActiveSupport::Duration",
      explanation: "Polling/sync interval for provider batch progress checks."
    },
    {
      key: "maximum_attempts",
      required: "Yes",
      accepted_values: "Integer >= 1",
      explanation: "Total candidate attempts allowed for one execution."
    },
    {
      key: "maximum_retries_per_candidate",
      required: "Yes",
      accepted_values: "Integer >= 0",
      explanation: "Retry count for a single provider/model candidate before fallback."
    },
    {
      key: "maximum_provider_fallbacks",
      required: "Yes",
      accepted_values: "Integer >= 0",
      explanation: "Maximum cross-provider fallback hops per execution."
    },
    {
      key: "maximum_profile_fallbacks",
      required: "Yes",
      accepted_values: "Integer >= 0",
      explanation: "Maximum profile-level fallback hops per execution."
    },
    {
      key: "profile_fallbacks",
      required: "No",
      accepted_values: "Hash profile_key => Array[profile_key]",
      explanation: "Fallback graph between profile tiers when primary profile fails."
    },
    {
      key: "request_timeout",
      required: "Yes",
      accepted_values: "Numeric >= 0 (seconds)",
      explanation: "Provider request timeout budget for non-streaming operations."
    },
    {
      key: "stream_idle_timeout",
      required: "Yes",
      accepted_values: "Numeric >= 0 (seconds)",
      explanation: "Maximum idle gap allowed while consuming streaming responses."
    },
    {
      key: "total_execution_timeout",
      required: "Yes",
      accepted_values: "Numeric >= 0 (seconds)",
      explanation: "Global wall-clock timeout for an execution, including retries/fallbacks."
    },
    {
      key: "retry_backoff_base",
      required: "Yes",
      accepted_values: "Numeric >= 0",
      explanation: "Base retry delay before jitter/backoff expansion."
    },
    {
      key: "retry_backoff_max",
      required: "Yes",
      accepted_values: "Numeric >= retry_backoff_base",
      explanation: "Upper bound for retry backoff delay."
    },
    {
      key: "retry_jitter",
      required: "Yes",
      accepted_values: "Numeric between 0 and 1",
      explanation: "Randomized jitter factor applied to retry delays."
    },
    {
      key: "retry_random",
      required: "Yes",
      accepted_values: "Callable returning a float-like random value",
      explanation: "Random source used by retry jitter calculations."
    },
    {
      key: "retry_sleeper",
      required: "Yes",
      accepted_values: "Callable(seconds)",
      explanation: "Sleeper callback used for retry backoff waiting."
    },
    {
      key: "maximum_attachment_count",
      required: "Yes",
      accepted_values: "Integer >= 0",
      explanation: "Maximum number of attachments accepted per request."
    },
    {
      key: "maximum_attachment_bytes",
      required: "Yes",
      accepted_values: "Integer >= 0 (bytes)",
      explanation: "Maximum size allowed for a single attachment payload."
    },
    {
      key: "maximum_attachment_total_bytes",
      required: "Yes",
      accepted_values: "Integer >= 0 (bytes)",
      explanation: "Maximum combined attachment size allowed in one request."
    },
    {
      key: "allowed_attachment_content_types",
      required: "No",
      accepted_values: "Array of MIME type strings",
      explanation: "Allowlist for attachment content types accepted by input normalization."
    },
    {
      key: "maximum_custom_tool_rounds",
      required: "Yes",
      accepted_values: "Integer >= 0",
      explanation: "Maximum number of model-to-tool-call rounds per execution."
    },
    {
      key: "custom_tool_timeout",
      required: "Yes",
      accepted_values: "Numeric >= 0 (seconds)",
      explanation: "Timeout budget for an individual custom tool execution."
    },
    {
      key: "maximum_custom_tool_result_size",
      required: "Yes",
      accepted_values: "Integer >= 0 (bytes)",
      explanation: "Maximum serialized size accepted for custom tool results."
    },
    {
      key: "custom_tool_confirmation_handler",
      required: "Yes",
      accepted_values: "Callable returning :approved/:rejected/:pending/:expired (booleans accepted for compatibility)",
      explanation: "Confirmation gate used for tools that require explicit approval."
    },
    {
      key: "retain_responses",
      required: "Yes",
      accepted_values: "Boolean",
      explanation: "Enable/disable persistence of retained provider responses."
    },
    {
      key: "response_retention_period",
      required: "Yes",
      accepted_values: "Positive ActiveSupport::Duration",
      explanation: "Retention TTL for persisted responses when response retention is enabled."
    },
    {
      key: "maximum_retained_response_size",
      required: "Yes",
      accepted_values: "Integer >= 0 (bytes)",
      explanation: "Hard cap on persisted response payload size."
    },
    {
      key: "execution_history_retention_period",
      required: "No",
      accepted_values: "nil or positive ActiveSupport::Duration",
      explanation: "Optional TTL for execution-history cleanup."
    },
    {
      key: "response_sanitizer",
      required: "No",
      accepted_values: "Callable or nil",
      explanation: "Optional sanitizer for normalized response payloads before persistence/logging."
    },
    {
      key: "instrumentation_enabled",
      required: "Yes",
      accepted_values: "Boolean",
      explanation: "Enable/disable instrumentation and notifications emitted by the gem."
    },
    {
      key: "notification_namespace",
      required: "Yes",
      accepted_values: "String",
      explanation: "Namespace prefix for ActiveSupport notification events."
    },
    {
      key: "admin_warning_thresholds",
      required: "No",
      accepted_values: "Hash",
      explanation: "Threshold settings for admin warning widgets and operational alerts."
    },
    {
      key: "admin_slow_call_threshold_ms",
      required: "Yes",
      accepted_values: "Integer >= 0",
      explanation: "Latency threshold (ms) used to classify calls as slow in admin screens."
    },
    {
      key: "admin_expensive_models",
      required: "No",
      accepted_values: "Array[String]",
      explanation: "Model identifiers considered expensive for admin analytics and warnings."
    },
    {
      key: "admin_actor_resolver",
      required: "No",
      accepted_values: "Callable(controller:) or nil",
      explanation: "Resolves the authenticated actor used by admin screens."
    },
    {
      key: "admin_visible_roots_resolver",
      required: "No",
      accepted_values: "Callable(actor:, controller:) or nil",
      explanation: "Limits visible roots in admin to those accessible by the actor."
    },
    {
      key: "admin_layout",
      required: "No",
      accepted_values: "Layout name String or nil",
      explanation: "Override for admin layout used by Recording Studio AI admin routes."
    }
  ].freeze

  CONFIG_EXAMPLE = <<~RUBY.freeze
    RecordingStudioAI.configure do |config|
      # API keys: provide the providers your profiles actually use.
      config.openai_api_key = Rails.application.credentials.dig(:openai, :api_key) || ENV.fetch("OPENAI_API_KEY", nil)
      config.gemini_api_key = Rails.application.credentials.dig(:gemini, :api_key) || ENV.fetch("GEMINI_API_KEY", nil)

      # Optional provider client injection for custom transport/testing.
      config.openai_client = nil
      config.gemini_client = nil

      # Profile routing. Reference models by their provider API model string.
      # Capabilities, tunable parameters, native tools, and modalities come from
      # the model registry (RecordingStudioAI.models), not from the profile entry.
      config.default_profile = :medium
      config.allowed_provider_overrides = []
      config.discovery_enabled = false
      config.profiles = {
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
      config.profile_fallbacks = {}
      config.providers = {
        openai: RecordingStudioAI::Providers::OpenAI.new(configuration: config),
        gemini: RecordingStudioAI::Providers::Gemini.new(configuration: config)
      }

      # Optional convenience APIs (outside this block):
      # RecordingStudioAI.register_provider(:my_provider, RecordingStudioAI::Providers::MyProvider.new(configuration: RecordingStudioAI.configuration))
      # RecordingStudioAI.discover_providers!

      # Authorization and attribution boundaries.
      config.authorization_handler = ->(**) { false }
      config.attribution_validator = ->(root_recording:, context_recording:) do
        # Keep host tenancy checks strict. Replace with host policy if needed.
        recording_class = RecordingStudio::Recording
        raise ArgumentError, "root must be a root recording" unless root_recording.is_a?(recording_class) && root_recording.parent_recording_id.nil?
        if context_recording && context_recording.root_recording_id != root_recording.id
          raise ArgumentError, "context must belong to root"
        end
      end

      # Cost + batch behavior.
      config.cost_catalogs = {}
      config.batch_synchronization_interval = 1.minute

      # Retry/attempt controls.
      config.maximum_attempts = 3
      config.maximum_retries_per_candidate = 1
      config.maximum_provider_fallbacks = 1
      config.maximum_profile_fallbacks = 1
      config.retry_backoff_base = 0.25
      config.retry_backoff_max = 5.0
      config.retry_jitter = 0.2
      config.retry_random = -> { rand }
      config.retry_sleeper = ->(seconds) { sleep(seconds) }

      # Timeout budgets (seconds).
      config.request_timeout = 120
      config.stream_idle_timeout = 30
      config.total_execution_timeout = 300

      # Attachment constraints.
      config.maximum_attachment_count = 10
      config.maximum_attachment_bytes = 20.megabytes
      config.maximum_attachment_total_bytes = 50.megabytes
      config.allowed_attachment_content_types = %w[
        image/png image/jpeg image/gif image/webp
        application/pdf application/json
        text/plain text/csv text/markdown
      ]

      # Custom tool controls.
      config.maximum_custom_tool_rounds = 5
      config.custom_tool_timeout = 30
      config.maximum_custom_tool_result_size = 256.kilobytes
      config.custom_tool_confirmation_handler = ->(**) { false }

      # Response/history retention.
      config.retain_responses = true
      config.response_retention_period = 7.days
      config.maximum_retained_response_size = 1.megabyte
      config.execution_history_retention_period = nil
      config.response_sanitizer = nil

      # Instrumentation and event naming.
      config.instrumentation_enabled = true
      config.notification_namespace = "recording_studio_ai"

      # Admin behavior.
      config.admin_warning_thresholds = RecordingStudioAI::Configuration.new.admin_warning_thresholds
      config.admin_slow_call_threshold_ms = 10_000
      config.admin_expensive_models = []
      config.admin_actor_resolver = nil
      config.admin_visible_roots_resolver = nil
      config.admin_layout = nil
    end
  RUBY

  PROVIDER_EXTENSION_EXAMPLE = <<~RUBY.freeze
    # Option A: Register directly from the host app (for example in an initializer)
    RecordingStudioAI.register_provider(
      :my_provider,
      RecordingStudioAI::Providers::MyProvider.new(configuration: RecordingStudioAI.configuration)
    )

    # Then reference it in a profile candidate list
    RecordingStudioAI.configure do |config|
      config.profiles[:medium] = [
        { provider: :my_provider, model: "my-default-model" },
        { provider: :openai, model: "gpt-5" }
      ]
    end

    # Option B: Register from another gem during boot
    # (inside your gem's Railtie or Engine initializer)
    module MyAIGem
      class Engine < ::Rails::Engine
        initializer "my_ai_gem.recording_studio_ai_provider" do
          RecordingStudioAI.register_provider(
            :my_provider,
            RecordingStudioAI::Providers::MyProvider.new(configuration: RecordingStudioAI.configuration)
          )
        end
      end
    end

    # Optional auto-discovery if provider classes are under
    # lib/recording_studio_ai/providers/*.rb
    RecordingStudioAI.configure do |config|
      config.discovery_enabled = true
    end
    RecordingStudioAI.discover_providers!
  RUBY

  MODEL_REGISTRATION_EXAMPLE = <<~RUBY.freeze
    # Built-in OpenAI and Gemini models ship with the gem under
    # lib/recording_studio_ai/models/<provider-key>/<model-key>.rb. Each file is a
    # registration script (no class). Add your own models the same way from a host
    # initializer or another gem's engine initializer.
    #
    # File layout for a host-provided model:
    #   config/initializers/recording_studio_ai_models.rb   (or any initializer)
    #
    # File naming convention for gem-style catalogs:
    #   lib/recording_studio_ai/models/openai/gpt-5-mini.rb
    #   lib/recording_studio_ai/models/gemini/gemini-2-5-pro.rb
    #   - the file/key is a lowercase hyphenated slug (dots become hyphens)
    #   - the :model value is the exact provider API model string

    RecordingStudioAI.models.register(
      provider: :openai,                 # required: provider key (must match a registered provider)
      key: "gpt-5",                      # required: stable slug, matches the filename
      model: "gpt-5",                    # required: exact provider API model string used in profiles
      display_name: "GPT-5",             # optional: label for admin/playground UI

      # Delivery/response modes the model supports.
      delivery: {
        streaming: true,
        structured_output: true,         # JSON schema / JSON output
        batch: true,
        batch_cancellation: true
      },

      # Tunable parameters. Declare support plus bounds/defaults so the playground
      # can render the right controls and requests can be validated.
      parameters: {
        temperature:       { supported: true, min: 0.0, max: 2.0, default: 1.0, step: 0.1 },
        verbosity:         { supported: true, values: %w[low medium high], default: "medium" },
        max_output_tokens: { supported: true, min: 1, max: 128_000, default: 8_192 },
        reasoning_effort:  { supported: true, values: %w[minimal low medium high], default: "medium" }
      },

      # Native/provider tools the model can use. custom_tools = host function calling.
      tools: %i[web_search file_search code_execution image_generation custom_tools],

      # Input/output modalities.
      modalities: {
        input:  %i[text image file],
        output: %i[text]
      }
    )

    # Look models up anywhere (used by the resolver and playground):
    RecordingStudioAI.models.fetch(:openai, "gpt-5")          # by API model string
    RecordingStudioAI.models.fetch_by_key(:openai, "gpt-5")   # by slug/key
    RecordingStudioAI.models.for_provider(:openai)            # all models for a provider
    RecordingStudioAI.models.all                              # every registered model
  RUBY

  PROFILE_EXAMPLE = <<~RUBY.freeze
    # Profiles are ordered preference lists. The resolver tries each candidate in
    # order and picks the first whose provider is configured and whose registered
    # model supports the request's required capabilities. Reference models by their
    # provider API model string; capabilities come from the model registry.
    RecordingStudioAI.configure do |config|
      config.default_profile = :medium
      config.profiles = {
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

      # Optional: allow one tier to fall back to another when no candidate resolves.
      config.profile_fallbacks = { high: [:medium], medium: [:low] }
    end
  RUBY

  CUSTOM_TOOLS_EXAMPLE = <<~RUBY.freeze
    # Register a custom tool (host app or another gem initializer)
    RecordingStudioAI.tools.register(
      key: "account_health_tool",
      version: 1,
      name: "Account Health Tool",
      description: "Returns a simple account health summary.",
      use_when: "You need account-level diagnostics.",
      do_not_use_when: "No account data is required.",
      parameters: [
        { name: "account_id", type: "string", required: true, description: "Account identifier" }
      ],
      returns: "A hash with score and status.",
      cost: "low",
      latency: "fast",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Host",
      executor: ->(arguments, _context) do
        account_id = arguments.fetch("account_id")
        { account_id: account_id, score: 87, status: "healthy" }
      end
    )

    # Use the tool in a generation call
    RecordingStudioAI.generate(
      root_recording: root_recording,
      initiator: current_user,
      initiator_kind: "user",
      execution_source: "web",
      profile: :medium,
      messages: [{ role: "user", content: "Check account health for account 42" }],
      custom_tools: [{ key: "account_health_tool", version: 1 }]
    )
  RUBY

  def show
    @config_options = CONFIG_OPTIONS
    @config_example = CONFIG_EXAMPLE
    @provider_extension_example = PROVIDER_EXTENSION_EXAMPLE
    @model_registration_example = MODEL_REGISTRATION_EXAMPLE
    @profile_example = PROFILE_EXAMPLE
    @custom_tools_example = CUSTOM_TOOLS_EXAMPLE
  end
end
