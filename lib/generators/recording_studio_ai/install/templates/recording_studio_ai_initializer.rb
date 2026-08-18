# frozen_string_literal: true

RecordingStudioAI.configure do |config|
  config.openai_api_key =
    Rails.application.credentials.dig(:openai, :api_key) || ENV.fetch("OPENAI_API_KEY", nil)
  config.gemini_api_key =
    Rails.application.credentials.dig(:gemini, :api_key) || ENV.fetch("GEMINI_API_KEY", nil)

  # Provider client objects may be injected for custom transport or testing.
  # config.openai_client = MyOpenAIClientFactory.build
  # config.gemini_client = MyGeminiClientFactory.build
  # Additional providers use the same names: config.<provider_key>_api_key and
  # config.<provider_key>_client, then RecordingStudioAI.register_provider.

  config.default_profile = :medium
  # Route each tier to ordered provider/model candidates. Reference models by
  # their provider API model string. Capabilities, tunable parameters, native
  # tools, and modalities come from the model registry (see the /config guide
  # and RecordingStudioAI.models.register). Edit this map for your own cost and
  # quality targets.
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
  # Rates are integer microunits per one million tokens, keyed by provider/model.
  config.cost_catalogs = {}
  # Polling runs through ActiveJob. Configure Rails with :sidekiq to use Sidekiq.
  config.batch_synchronization_job = "RecordingStudioAI::BatchSynchronizationJob"
  config.batch_synchronization_interval = 1.minute
  # Replace this deny-by-default handler with the host's RecordingStudioAccessible policy.
  config.authorization_handler = ->(**) { false }
  # Core validates Recording Studio root/context tenancy. Override only for a stricter host policy.
  # config.attribution_validator = ->(root_recording:, context_recording:) { ... }
  # Normal application code should use profiles. Enable only intentional overrides.
  config.allowed_provider_overrides = []
  config.retain_responses = false
  config.response_retention_period = 7.days
  config.maximum_retained_response_size = 1.megabyte
  # Canonical execution history is never deleted unless this is explicitly enabled.
  config.execution_history_retention_period = nil
  # Receives recursively normalized, built-in-sanitized Hash/Array/scalar values.
  config.response_sanitizer = nil
  config.instrumentation_enabled = true
  config.notification_namespace = "recording_studio_ai"
  config.admin_warning_thresholds = RecordingStudioAI::Configuration.new.admin_warning_thresholds
  config.admin_slow_call_threshold_ms = 10_000
  # Admin access fails closed until the host resolves an authenticated actor and visible roots.
  # config.admin_actor_resolver = ->(controller:) { controller.current_user }
  # config.admin_visible_roots_resolver = ->(actor:, controller:) { actor.workspaces.pluck(:recording_id) }
  # config.admin_layout = "flat_pack_sidebar"
  config.maximum_attempts = 3
  config.maximum_attachment_count = 10
  config.maximum_attachment_bytes = 20.megabytes
  config.maximum_attachment_total_bytes = 50.megabytes
  config.allowed_attachment_content_types = %w[
    image/png image/jpeg image/gif image/webp application/pdf application/json
    text/plain text/csv text/markdown
  ]
  config.maximum_retries_per_candidate = 1
  # Retry delays are seconds. Jitter must be between 0.0 and 1.0.
  config.retry_backoff_base = 0.25
  config.retry_backoff_max = 5.0
  config.retry_jitter = 0.2
  config.maximum_provider_fallbacks = 1
  config.maximum_profile_fallbacks = 1
  # Profile-tier fallback is disabled unless explicitly mapped, for example: { high: [:medium] }.
  config.profile_fallbacks = {}
  config.maximum_custom_tool_rounds = 5
  config.custom_tool_timeout = 30
  config.maximum_custom_tool_result_size = 256.kilobytes
  # Return :approved, :rejected, :pending, or :expired. Booleans remain accepted for compatibility.
  # Replace this deny-by-default handler when the host application has an approval flow.
  config.custom_tool_confirmation_handler = ->(**) { false }
  config.total_execution_timeout = 300
  config.request_timeout = 120
  config.stream_idle_timeout = 30
end
