# frozen_string_literal: true

require_relative "constants"

RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-5-pro",
  model: "gpt-5-pro",
  display_name: "GPT-5 Pro",
  delivery: RecordingStudioAI::Models::Openai::Constants::DELIVERY,
  parameters: {
    temperature: RecordingStudioAI::Models::Openai::Constants::TEMPERATURE,
    verbosity: RecordingStudioAI::Models::Openai::Constants.verbosity(default: "high"),
    max_output_tokens: RecordingStudioAI::Models::Openai::Constants.max_output_tokens(default: 16_384),
    reasoning_effort: RecordingStudioAI::Models::Openai::Constants.reasoning_effort(default: "high")
  },
  tools: RecordingStudioAI::Models::Openai::Constants::FULL_TOOLS,
  modalities: RecordingStudioAI::Models::Openai::Constants::MODALITIES
)
