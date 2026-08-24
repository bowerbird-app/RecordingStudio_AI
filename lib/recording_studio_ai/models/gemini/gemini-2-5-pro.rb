# frozen_string_literal: true

require_relative "constants"

RecordingStudioAI.models.register(
  provider: :gemini,
  key: "gemini-2-5-pro",
  model: "gemini-2.5-pro",
  display_name: "Gemini 2.5 Pro",
  delivery: RecordingStudioAI::Models::Gemini::Constants::DELIVERY,
  parameters: {
    temperature: RecordingStudioAI::Models::Gemini::Constants::TEMPERATURE,
    max_output_tokens: RecordingStudioAI::Models::Gemini::Constants.max_output_tokens(default: 8_192)
  },
  tools: RecordingStudioAI::Models::Gemini::Constants::TOOLS,
  modalities: RecordingStudioAI::Models::Gemini::Constants::MODALITIES
)
