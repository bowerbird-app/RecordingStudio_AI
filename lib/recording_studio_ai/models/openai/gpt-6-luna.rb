# frozen_string_literal: true

require_relative "constants"

# Generation fields follow gpt-5. Hosted chat uses the same registration.
# reasoning.effort: none, low, medium (default), high, xhigh, max.
RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-6-luna",
  model: "gpt-6-luna",
  display_name: "GPT-6 Luna",
  operations: %i[generation hosted_agent],
  delivery: RecordingStudioAI::Models::Openai::Constants::DELIVERY,
  parameters: {
    temperature: RecordingStudioAI::Models::Openai::Constants::TEMPERATURE,
    verbosity: RecordingStudioAI::Models::Openai::Constants.verbosity(default: "medium"),
    max_output_tokens: RecordingStudioAI::Models::Openai::Constants.max_output_tokens(default: 8_192),
    reasoning_effort: RecordingStudioAI::Models::Openai::Constants.reasoning_effort(
      default: "medium",
      values: %w[none low medium high xhigh max]
    )
  },
  tools: RecordingStudioAI::Models::Openai::Constants::FULL_TOOLS,
  modalities: RecordingStudioAI::Models::Openai::Constants::MODALITIES
)
