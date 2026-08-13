# frozen_string_literal: true

RecordingStudioAI.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
  config.gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)
  config.allowed_provider_overrides = %i[openai gemini]

  config.default_profile = :medium
  config.profiles = {
    low: [
      { provider: :openai, model: "gpt-5-mini",
        capabilities: %i[generation streaming structured_output image_input file_input provider_native_web_search custom_tools provider_batch provider_batch_cancellation] },
      { provider: :gemini, model: "gemini-2.5-flash",
        capabilities: %i[generation streaming structured_output image_input file_input provider_native_web_search custom_tools provider_batch provider_batch_cancellation] }
    ],
    medium: [
      { provider: :openai, model: "gpt-5",
        capabilities: %i[generation streaming structured_output image_input file_input provider_native_web_search custom_tools provider_batch provider_batch_cancellation] },
      { provider: :gemini, model: "gemini-2.5-pro",
        capabilities: %i[generation streaming structured_output image_input file_input provider_native_web_search custom_tools provider_batch provider_batch_cancellation] }
    ],
    high: [
      { provider: :openai, model: "gpt-5-pro",
        capabilities: %i[generation streaming structured_output image_input file_input provider_native_web_search custom_tools provider_batch provider_batch_cancellation] },
      { provider: :gemini, model: "gemini-2.5-pro",
        capabilities: %i[generation streaming structured_output image_input file_input provider_native_web_search custom_tools provider_batch provider_batch_cancellation] }
    ]
  }
  config.authorization_handler = ->(action:, attribution:, context:) { true }
  config.attribution_validator = lambda do |root_recording:, context_recording:|
    unless root_recording.is_a?(RecordingStudio::Recording) &&
           root_recording.parent_recording_id.nil? &&
           root_recording.root_recording_id == root_recording.id
      raise ArgumentError, "root_recording must be a Recording Studio root"
    end
    if context_recording && context_recording.root_recording_id != root_recording.id
      raise ArgumentError, "context_recording must belong to root_recording"
    end
  end
  config.retain_responses = true
  config.response_retention_period = 7.days
  config.maximum_retained_response_size = 1.megabyte
  config.admin_actor_resolver = ->(controller:) { Current.actor }
  config.admin_visible_roots_resolver = lambda do |actor:, controller:|
    RecordingStudio::Recording.where(parent_recording_id: nil).pluck(:id)
  end
  config.admin_layout = "flat_pack_sidebar"
  config.maximum_attempts = 3
  config.maximum_retries_per_candidate = 1
  config.maximum_provider_fallbacks = 1
  config.maximum_custom_tool_rounds = 5
  config.request_timeout = 120
  config.stream_idle_timeout = 30
end

DUMMY_TOOLS = [
  {
    key: "dummy_echo_tool",
    version: 1,
    name: "Dummy Echo Tool",
    description: "Echoes input text with lightweight context metadata for playground validation.",
    use_when: "You need to echo or lightly transform user text.",
    do_not_use_when: "No tool call is needed to answer the user prompt.",
    parameters: [
      {
        name: "input",
        type: "string",
        required: true,
        description: "The text to echo back."
      }
    ],
    returns: "A hash with echoed text and run metadata.",
    cost: "negligible",
    latency: "instant",
    read_only: true,
    destructive: false,
    requires_confirmation: false,
    idempotent: true,
    executor_label: "Dummy",
    executor: lambda do |arguments, context|
      {
        echoed: arguments.fetch("input"),
        run_id: context.run.id,
        root_recording_id: context.root_recording.id,
        requested_at: Time.current.iso8601
      }
    end
  },
  {
    key: "dummy_summary_tool",
    version: 1,
    name: "Dummy Summary Tool",
    description: "Returns a short summary preview of the provided text.",
    use_when: "You need a compact summary-style preview before finalizing an answer.",
    do_not_use_when: "The prompt is already concise or a verbatim response is required.",
    parameters: [
      {
        name: "input",
        type: "string",
        required: true,
        description: "The text to summarize."
      }
    ],
    returns: "A hash with summary text and character counts.",
    cost: "negligible",
    latency: "instant",
    read_only: true,
    destructive: false,
    requires_confirmation: false,
    idempotent: true,
    executor_label: "Dummy",
    executor: lambda do |arguments, _context|
      input = arguments.fetch("input").to_s.strip
      preview = input[0, 180]
      {
        summary: preview,
        truncated: input.length > preview.length,
        input_characters: input.length,
        summary_characters: preview.length
      }
    end
  },
  {
    key: "dummy_keyword_tool",
    version: 1,
    name: "Dummy Keyword Tool",
    description: "Extracts a simple set of keywords from input text for classification demos.",
    use_when: "You want rough topical tags for a sentence or paragraph.",
    do_not_use_when: "Precise NLP extraction is required.",
    parameters: [
      {
        name: "input",
        type: "string",
        required: true,
        description: "The text to analyze for keyword candidates."
      }
    ],
    returns: "A hash with up to 8 deduplicated keyword candidates.",
    cost: "negligible",
    latency: "instant",
    read_only: true,
    destructive: false,
    requires_confirmation: false,
    idempotent: true,
    executor_label: "Dummy",
    executor: lambda do |arguments, _context|
      tokens = arguments.fetch("input").to_s.downcase.scan(/[a-z0-9_]{3,}/)
      keywords = tokens.uniq.first(8)
      {
        keywords: keywords,
        keyword_count: keywords.length
      }
    end
  }
].freeze

DUMMY_TOOLS.each do |tool_definition|
  next if RecordingStudioAI.tools.fetch(tool_definition.fetch(:key), version: tool_definition.fetch(:version))

  RecordingStudioAI.tools.register(**tool_definition)
end
