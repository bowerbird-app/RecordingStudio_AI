# frozen_string_literal: true

RecordingStudioAI.models.register(
  provider: :typesafe,
  key: "jev-latest",
  model: "jev-latest",
  display_name: "Jev",
  operations: [:decision],
  decision_types: %i[choice score noul],
  modalities: { input: [:text], output: [] }
)
