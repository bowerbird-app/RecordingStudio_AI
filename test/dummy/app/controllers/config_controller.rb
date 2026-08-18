# frozen_string_literal: true

class ConfigController < ApplicationController
  CONFIG_OPTIONS = [
    {
      key: "openai_api_key",
      required: "When using OpenAI",
      accepted_values: "String or nil",
      default: 'ENV["OPENAI_API_KEY"]',
      explanation: "OpenAI API key."
    },
    {
      key: "gemini_api_key",
      required: "When using Gemini",
      accepted_values: "String or nil",
      default: 'ENV["GEMINI_API_KEY"]',
      explanation: "Gemini API key."
    },
    {
      key: "openai_client",
      required: "No",
      accepted_values: "Client object or nil",
      default: "nil",
      explanation: "Swap in your own OpenAI client for tests or custom transport."
    },
    {
      key: "gemini_client",
      required: "No",
      accepted_values: "Client object or nil",
      default: "nil",
      explanation: "Swap in your own Gemini client for tests or custom transport."
    },
    {
      key: "default_profile",
      required: "No",
      accepted_values: "Symbol, for example :low, :medium, :high",
      default: ":medium",
      explanation: "Profile used when a request does not pick one."
    },
    {
      key: "profiles",
      required: "No",
      accepted_values: "Hash of profile keys to ordered { provider:, model: } lists",
      default: "low / medium / high built-in maps",
      explanation: "Preferred provider and model order for generate (including stream: true) and batch."
    },
    {
      key: "allowed_provider_overrides",
      required: "No",
      accepted_values: "Array of provider symbols",
      default: "[]",
      explanation: "Providers a caller may force. Leave empty to stay on profiles."
    },
    {
      key: "providers",
      required: "No",
      accepted_values: "Hash of provider symbol => provider object",
      default: "OpenAI and Gemini adapters",
      explanation: "Registered providers. Override for a custom adapter or tests."
    },
    {
      key: "discovery_enabled",
      required: "No",
      accepted_values: "true or false",
      default: "false",
      explanation: "Auto-register provider classes under lib/recording_studio_ai/providers."
    },
    {
      key: "authorization_handler",
      required: "No",
      accepted_values: "Callable returning literal true or false",
      default: "->(**) { false }",
      explanation: "Return literal true to allow. Prefer RecordingStudioAI::AccessibleAuthorization once Accessible is installed."
    },
    {
      key: "attribution_validator",
      required: "No",
      accepted_values: "Callable(root_recording:, context_recording:)",
      default: "built-in root and context check",
      explanation: "Checks that the workspace root and context belong together."
    },
    {
      key: "cost_catalogs",
      required: "No",
      accepted_values: "Hash of provider/model rates",
      default: "{}",
      explanation: "Optional prices for spend estimates. Use microunits per 1M tokens."
    },
    {
      key: "batch_synchronization_job",
      required: "No",
      accepted_values: "ActiveJob class or class-name String",
      default: '"RecordingStudioAI::BatchSynchronizationJob"',
      explanation: "Job that polls provider batches. Uses Sidekiq when that is the ActiveJob adapter."
    },
    {
      key: "batch_synchronization_interval",
      required: "No",
      accepted_values: "Positive duration",
      default: "1.minute",
      explanation: "How often batch polling runs."
    },
    {
      key: "maximum_attempts",
      required: "No",
      accepted_values: "Integer >= 1",
      default: "3",
      explanation: "How many tries one call may take across retries and fallbacks."
    },
    {
      key: "maximum_retries_per_candidate",
      required: "No",
      accepted_values: "Integer >= 0",
      default: "1",
      explanation: "Retries on the same provider and model before moving on."
    },
    {
      key: "maximum_provider_fallbacks",
      required: "No",
      accepted_values: "Integer >= 0",
      default: "1",
      explanation: "How many times a call may switch provider."
    },
    {
      key: "maximum_profile_fallbacks",
      required: "No",
      accepted_values: "Integer >= 0",
      default: "1",
      explanation: "How many times a call may drop to another profile tier."
    },
    {
      key: "profile_fallbacks",
      required: "No",
      accepted_values: "Hash of profile_key => [profile_key]",
      default: "{}",
      explanation: "Which profile to try next. Empty means no tier fallback."
    },
    {
      key: "request_timeout",
      required: "No",
      accepted_values: "Number of seconds >= 0",
      default: "120",
      explanation: "Timeout for a non-streaming provider request."
    },
    {
      key: "stream_idle_timeout",
      required: "No",
      accepted_values: "Number of seconds >= 0",
      default: "30",
      explanation: "How long a stream may sit idle before it is cut off."
    },
    {
      key: "total_execution_timeout",
      required: "No",
      accepted_values: "Number of seconds >= 0",
      default: "300",
      explanation: "Wall-clock limit for a whole call, including retries."
    },
    {
      key: "retry_backoff_base",
      required: "No",
      accepted_values: "Number of seconds >= 0",
      default: "0.25",
      explanation: "Starting wait before the next retry."
    },
    {
      key: "retry_backoff_max",
      required: "No",
      accepted_values: "Number of seconds >= retry_backoff_base",
      default: "5.0",
      explanation: "Longest wait between retries."
    },
    {
      key: "retry_jitter",
      required: "No",
      accepted_values: "Number from 0 to 1",
      default: "0.2",
      explanation: "Random spread added to retry waits."
    },
    {
      key: "retry_random",
      required: "No",
      accepted_values: "Callable that returns a float",
      default: "-> { rand }",
      explanation: "Random source for retry jitter. Override in tests."
    },
    {
      key: "retry_sleeper",
      required: "No",
      accepted_values: "Callable(seconds)",
      default: "->(seconds) { sleep(seconds) }",
      explanation: "Wait helper for retry backoff. Override in tests."
    },
    {
      key: "maximum_attachment_count",
      required: "No",
      accepted_values: "Integer >= 0",
      default: "10",
      explanation: "How many files one request may attach."
    },
    {
      key: "maximum_attachment_bytes",
      required: "No",
      accepted_values: "Integer bytes >= 0",
      default: "20.megabytes",
      explanation: "Largest size for one attached file."
    },
    {
      key: "maximum_attachment_total_bytes",
      required: "No",
      accepted_values: "Integer bytes >= 0",
      default: "50.megabytes",
      explanation: "Largest combined size for all attachments on one request."
    },
    {
      key: "allowed_attachment_content_types",
      required: "No",
      accepted_values: "Array of MIME type strings",
      default: "png, jpeg, gif, webp, pdf, json, plain, csv, markdown",
      explanation: "File types the addon will accept."
    },
    {
      key: "maximum_custom_tool_rounds",
      required: "No",
      accepted_values: "Integer >= 0",
      default: "5",
      explanation: "How many tool-call rounds one generate may run."
    },
    {
      key: "custom_tool_timeout",
      required: "No",
      accepted_values: "Number of seconds >= 0",
      default: "30",
      explanation: "Timeout for one custom tool run."
    },
    {
      key: "maximum_custom_tool_result_size",
      required: "No",
      accepted_values: "Integer bytes >= 0",
      default: "256.kilobytes",
      explanation: "Largest result a custom tool may return."
    },
    {
      key: "custom_tool_confirmation_handler",
      required: "No",
      accepted_values: ":approved, :rejected, :pending, :expired, or a boolean",
      default: "->(**) { false }",
      explanation: "Approve or reject tools that need a human yes. Ships closed."
    },
    {
      key: "retain_responses",
      required: "No",
      accepted_values: "true or false",
      default: "false",
      explanation: "Keep a copy of provider responses."
    },
    {
      key: "response_retention_period",
      required: "No",
      accepted_values: "Positive duration",
      default: "7.days",
      explanation: "How long kept responses stay around."
    },
    {
      key: "maximum_retained_response_size",
      required: "No",
      accepted_values: "Integer bytes >= 0",
      default: "1.megabyte",
      explanation: "Largest response the addon will store."
    },
    {
      key: "execution_history_retention_period",
      required: "No",
      accepted_values: "nil or a positive duration",
      default: "nil",
      explanation: "Optional cleanup window for run history. nil keeps it."
    },
    {
      key: "response_sanitizer",
      required: "No",
      accepted_values: "Callable or nil",
      default: "nil",
      explanation: "Optional extra clean-up after the built-in sanitizer."
    },
    {
      key: "instrumentation_enabled",
      required: "No",
      accepted_values: "true or false",
      default: "true",
      explanation: "Emit notifications the host can subscribe to."
    },
    {
      key: "notification_namespace",
      required: "No",
      accepted_values: "String",
      default: '"recording_studio_ai"',
      explanation: "Prefix for those notification names."
    },
    {
      key: "admin_warning_thresholds",
      required: "No",
      accepted_values: "Hash of warning keys to numbers",
      default: "built-in warning thresholds",
      explanation: "When admin warning widgets light up."
    },
    {
      key: "admin_slow_call_threshold_ms",
      required: "No",
      accepted_values: "Integer milliseconds >= 0",
      default: "10_000",
      explanation: "Latency that counts as a slow call on admin screens."
    },
    {
      key: "admin_expensive_models",
      required: "No",
      accepted_values: "Array of model name strings",
      default: "[]",
      explanation: "Models treated as expensive in admin warnings."
    },
    {
      key: "admin_actor_resolver",
      required: "For admin",
      accepted_values: "Callable(controller:) or nil",
      default: "nil",
      explanation: "Who is looking at admin. Admin stays closed until you set this."
    },
    {
      key: "admin_authenticate",
      required: "Recommended for admin",
      accepted_values: "Callable(controller:) or nil",
      default: "nil",
      explanation: "Optional extra authenticate step on engine admin. The engine does not authenticate by itself — also authenticate ApplicationController."
    },
    {
      key: "admin_visible_roots_resolver",
      required: "For admin",
      accepted_values: "Callable(actor:, controller:) or nil",
      default: "nil",
      explanation: "Which workspaces that person may see. Dummy uses Accessible root ids; admin stays closed until you set this."
    },
    {
      key: "admin_layout",
      required: "No",
      accepted_values: "Layout name String or nil",
      default: "nil",
      explanation: "Host layout for admin screens. nil uses the app layout."
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
      config.batch_synchronization_job = "RecordingStudioAI::BatchSynchronizationJob"
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
      config.retain_responses = false
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
      config.admin_authenticate = nil
      config.admin_visible_roots_resolver = nil
      config.admin_layout = nil
    end
  RUBY

  PROVIDER_EXTENSION_EXAMPLE = <<~RUBY.freeze
    # Credentials follow the provider_key, the same way OpenAI and Gemini do:
    #   config.my_provider_api_key = ENV.fetch("MY_PROVIDER_API_KEY", nil)
    #   config.my_provider_client = MyClient.new   # optional injected transport

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

    # Use the tool in a generation call. Streaming is the same method with stream: true.
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
