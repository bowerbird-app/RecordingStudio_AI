# frozen_string_literal: true

require_relative "constants"

RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-5",
  model: "gpt-5",
  display_name: "GPT-5",
  delivery: RecordingStudioAI::Models::Openai::Constants::DELIVERY,
  parameters: {
    temperature: RecordingStudioAI::Models::Openai::Constants::TEMPERATURE,
    verbosity: RecordingStudioAI::Models::Openai::Constants.verbosity(default: "medium"),
    max_output_tokens: RecordingStudioAI::Models::Openai::Constants.max_output_tokens(default: 8_192),
    reasoning_effort: RecordingStudioAI::Models::Openai::Constants.reasoning_effort(default: "medium")
  },
  tools: RecordingStudioAI::Models::Openai::Constants::FULL_TOOLS,
  modalities: RecordingStudioAI::Models::Openai::Constants::MODALITIES
)
