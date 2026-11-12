# frozen_string_literal: true

module RecordingStudioAI
  module Credits
    module_function

    def feature_extras(prompt, tools)
      parts = prompt_parts(prompt).merge(tool_parts(Array(tools)))
      parts.merge(
        fee: parts.fetch(:prompt_fee) + parts.fetch(:tool_fee),
        multiplier: parts.fetch(:prompt_multiplier) * parts.fetch(:tool_multiplier)
      )
    end

    def prompt_parts(prompt)
      {
        prompt_key: prompt&.key,
        prompt_fee: prompt&.credit_fee.to_i,
        prompt_multiplier: prompt&.credit_multiplier || 1
      }
    end

    def tool_parts(tools)
      {
        tool_keys: tools.map { |tool| tool.key.to_s }.freeze,
        tool_fee: tools.sum { |tool| tool.credit_fee.to_i },
        tool_multiplier: tools.reduce(1) { |product, tool| product * (tool.credit_multiplier || 1) }
      }
    end

    private_class_method :feature_extras, :prompt_parts, :tool_parts
  end
end
