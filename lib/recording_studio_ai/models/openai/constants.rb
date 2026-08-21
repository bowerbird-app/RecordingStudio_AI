# frozen_string_literal: true

module RecordingStudioAI
  module Models
    module Openai
      # Shared registration templates for built-in OpenAI models.
      module Constants
        DELIVERY = {
          streaming: true,
          structured_output: true,
          batch: true,
          batch_cancellation: true
        }.freeze

        MODALITIES = {
          input: %i[text image file],
          output: %i[text]
        }.freeze

        TEMPERATURE = { type: :number, min: 0.0, max: 2.0, default: 1.0, step: 0.1 }.freeze

        FULL_TOOLS = %i[web_search file_search code_execution image_generation custom_tools].freeze
        MINI_TOOLS = %i[web_search file_search code_execution custom_tools].freeze

        module_function

        def verbosity(default:)
          { type: :string, values: %w[low medium high], default: default }
        end

        def reasoning_effort(default:)
          { type: :string, values: %w[minimal low medium high], default: default }
        end

        def max_output_tokens(default:)
          { type: :integer, min: 1, max: 128_000, default: default }
        end
      end
    end
  end
end
