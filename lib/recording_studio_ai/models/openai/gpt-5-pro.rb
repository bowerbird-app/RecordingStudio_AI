# frozen_string_literal: true

RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-5-pro",
  model: "gpt-5-pro",
  display_name: "GPT-5 Pro",
  delivery: {
    streaming: true,
    structured_output: true,
    batch: true,
    batch_cancellation: true
  },
  parameters: {
    temperature: { supported: true, min: 0.0, max: 2.0, default: 1.0, step: 0.1 },
    verbosity: { supported: true, values: %w[low medium high], default: "high" },
    max_output_tokens: { supported: true, min: 1, max: 128_000, default: 16_384 },
    reasoning_effort: { supported: true, values: %w[minimal low medium high], default: "high" }
  },
  tools: %i[web_search file_search code_execution image_generation custom_tools],
  modalities: {
    input: %i[text image file],
    output: %i[text]
  }
)
