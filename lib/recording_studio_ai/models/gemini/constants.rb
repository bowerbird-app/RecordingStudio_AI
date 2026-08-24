# frozen_string_literal: true

module RecordingStudioAI
  module Models
    module Gemini
      # Shared registration templates for built-in Gemini models.
      module Constants
        DELIVERY = {
          streaming: true,
          structured_output: true,
          batch: true,
          batch_cancellation: true
        }.freeze

        MODALITIES = {
          input: %i[text image audio video file],
          output: %i[text]
        }.freeze

        TEMPERATURE = { type: :number, min: 0.0, max: 2.0, default: 1.0, step: 0.1 }.freeze

        TOOLS = %i[web_search code_execution custom_tools].freeze

        module_function

        def max_output_tokens(default:)
          { type: :integer, min: 1, max: 65_536, default: default }
        end
      end
    end
  end
end
