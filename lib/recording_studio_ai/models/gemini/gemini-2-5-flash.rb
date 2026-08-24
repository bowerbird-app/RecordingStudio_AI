# frozen_string_literal: true

require_relative "constants"

RecordingStudioAI.models.register(
  provider: :gemini,
  key: "gemini-2-5-flash",
  model: "gemini-2.5-flash",
  display_name: "Gemini 2.5 Flash",
  delivery: RecordingStudioAI::Models::Gemini::Constants::DELIVERY,
  parameters: {
    temperature: RecordingStudioAI::Models::Gemini::Constants::TEMPERATURE,
    max_output_tokens: RecordingStudioAI::Models::Gemini::Constants.max_output_tokens(default: 4_096)
  },
  tools: RecordingStudioAI::Models::Gemini::Constants::TOOLS,
  modalities: RecordingStudioAI::Models::Gemini::Constants::MODALITIES
)
