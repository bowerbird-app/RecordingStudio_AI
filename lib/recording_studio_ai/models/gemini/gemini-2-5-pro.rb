# frozen_string_literal: true

RecordingStudioAI.models.register(
  provider: :gemini,
  key: "gemini-2-5-pro",
  model: "gemini-2.5-pro",
  display_name: "Gemini 2.5 Pro",
  delivery: {
    streaming: true,
    structured_output: true,
    batch: true,
    batch_cancellation: true
  },
  parameters: {
    temperature: { type: :number, min: 0.0, max: 2.0, default: 1.0, step: 0.1 },
    max_output_tokens: { type: :integer, min: 1, max: 65_536, default: 8_192 }
  },
  tools: %i[web_search code_execution custom_tools],
  modalities: {
    input: %i[text image audio video file],
    output: %i[text]
  }
)
