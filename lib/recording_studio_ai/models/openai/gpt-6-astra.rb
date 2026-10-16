# frozen_string_literal: true

# Documented Agents API model. Generation models stay generation-only; hosted
# sessions resolve only when a definition lists the hosted_agent operation.
RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-6-astra",
  model: "gpt-6-astra",
  display_name: "GPT-6 Astra",
  operations: [:hosted_agent],
  modalities: { input: [:text], output: [:text] }
)
