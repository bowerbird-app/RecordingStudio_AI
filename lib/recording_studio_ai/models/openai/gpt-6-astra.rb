# frozen_string_literal: true

require_relative "constants"

# Documented Agents API model. Generation models stay generation-only; hosted
# sessions resolve only when a definition lists the hosted_agent operation.
# `none` is rejected by OpenAI for this model, so it is not an allowed effort.
# No default: hosted chat omits reasoning unless a profile entry sets one.
RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-6-astra",
  model: "gpt-6-astra",
  display_name: "GPT-6 Astra",
  operations: [:hosted_agent],
  parameters: {
    reasoning_effort: RecordingStudioAI::Models::Openai::Constants.reasoning_effort(
      values: %w[low medium high xhigh max]
    )
  },
  modalities: { input: [:text], output: [:text] }
)
