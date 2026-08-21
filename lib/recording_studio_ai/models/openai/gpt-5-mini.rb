# frozen_string_literal: true

require_relative "constants"

RecordingStudioAI.models.register(
  provider: :openai,
  key: "gpt-5-mini",
  model: "gpt-5-mini",
  display_name: "GPT-5 Mini",
  delivery: RecordingStudioAI::Models::Openai::Constants::DELIVERY,
  parameters: {
    temperature: RecordingStudioAI::Models::Openai::Constants::TEMPERATURE,
    verbosity: RecordingStudioAI::Models::Openai::Constants.verbosity(default: "medium"),
    max_output_tokens: RecordingStudioAI::Models::Openai::Constants.max_output_tokens(default: 4_096),
    reasoning_effort: RecordingStudioAI::Models::Openai::Constants.reasoning_effort(default: "medium")
  },
  tools: RecordingStudioAI::Models::Openai::Constants::MINI_TOOLS,
  modalities: RecordingStudioAI::Models::Openai::Constants::MODALITIES
)
