# frozen_string_literal: true

RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-5-mini",
  model: "gpt-5-mini",
  display_name: "GPT-5 Mini",
  delivery: {
    streaming: true,
    structured_output: true,
    batch: true,
    batch_cancellation: true
  },
  parameters: {
    temperature: { type: :number, min: 0.0, max: 2.0, default: 1.0, step: 0.1 },
    verbosity: { type: :string, values: %w[low medium high], default: "medium" },
    max_output_tokens: { type: :integer, min: 1, max: 128_000, default: 4_096 },
    reasoning_effort: { type: :string, values: %w[minimal low medium high], default: "medium" }
  },
  tools: %i[web_search file_search code_execution custom_tools],
  modalities: {
    input: %i[text image file],
    output: %i[text]
  }
)
