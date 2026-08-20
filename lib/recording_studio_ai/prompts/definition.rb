# frozen_string_literal: true

module RecordingStudioAI
  module Prompts
    class Definition
      PLACEHOLDER = /\{\{([a-z][a-z0-9_]*)\}\}/.freeze
      ROLES = %w[system user assistant].freeze

      attr_reader :owner, :key, :version, :name, :description,
                  :messages, :inputs, :tools, :defaults, :overridable

      def initialize(
        owner: nil,
        key:,
        version:,
        name:,
        description:,
        messages:,
        inputs:,
        tools: [],
        defaults: {},
        overridable: true
      )
        @owner = owner.nil? ? nil : normalize_owner(owner)
        @key = normalize_identifier(key, "prompt key")
        @version = version
        @name = name.to_s.strip
        @description = description.to_s.strip
        @inputs = normalize_inputs(inputs)
        @messages = normalize_messages(messages)
        @tools = normalize_tools(tools)
        @defaults = RecordingStudioAI::Contracts::Containment.ensure_serializable!(defaults, path: "prompt.defaults").freeze
        @overridable = normalize_overridable(overridable)

        validate!
        freeze
      end

      def overridable?
        overridable
      end

      def render(inputs)
        values = RecordingStudioAI::Contracts::Containment.ensure_serializable!(inputs, path: "prompt.inputs")
        unknown = values.keys - @inputs
        missing = @inputs - values.keys
        validation_error!("prompt inputs include unknown values: #{unknown.join(', ')}") if unknown.any?
        validation_error!("prompt inputs are missing: #{missing.join(', ')}") if missing.any?

        messages.map do |message|
          message.merge(content: message.fetch(:content).gsub(PLACEHOLDER) { values.fetch(Regexp.last_match(1)).to_s })
        end
      end

      private

      # Who registered the prompt (a gem or the host app), not an actor.
      # Prefer labels like RecordingStudioAI, Host, or RecordingStudioAdmin.
      def normalize_owner(value)
        owner = value.to_s.strip
        validation_error!("prompt owner must be a non-empty label") if owner.empty?
        unless owner.match?(/\A[A-Za-z][A-Za-z0-9]*\z/)
          validation_error!("prompt owner must be a gem or host label (e.g. RecordingStudioAI, Host)")
        end

        owner
      end

      def normalize_identifier(value, label)
        identifier = value.to_s
        validation_error!("#{label} must be snake_case") unless identifier.match?(/\A[a-z][a-z0-9_]*\z/)

        identifier
      end

      def normalize_overridable(value)
        return value if value.equal?(true) || value.equal?(false)

        validation_error!("prompt overridable must be true or false")
      end

      def normalize_inputs(value)
        unless value.is_a?(Array) && value.all? { |input| input.to_s.match?(/\A[a-z][a-z0-9_]*\z/) }
          validation_error!("prompt inputs must be an Array of snake_case names")
        end

        normalized = value.map(&:to_s)
        validation_error!("prompt inputs must be unique") if normalized.uniq.length != normalized.length

        normalized.freeze
      end

      def normalize_messages(value)
        unless value.is_a?(Array) && value.any?
          validation_error!("prompt messages must be a non-empty Array")
        end

        value.map.with_index do |message, index|
          unless message.is_a?(Hash)
            validation_error!("prompt messages[#{index}] must be a Hash")
          end

          normalized = message.transform_keys(&:to_sym)
          unless normalized.keys == %i[role content] && ROLES.include?(normalized[:role].to_s) && normalized[:content].is_a?(String) && normalized[:content].strip.present?
            validation_error!("prompt messages[#{index}] must include a valid role and non-empty content")
          end

          { role: normalized[:role].to_s, content: normalized[:content] }.freeze
        end.freeze
      end

      def normalize_tools(value)
        unless value.is_a?(Array)
          validation_error!("prompt tools must be an Array")
        end

        value.map.with_index do |tool, index|
          normalized = tool.is_a?(Hash) ? tool.transform_keys(&:to_sym) : { key: tool }
          unless normalized.keys.all? { |key| %i[key version].include?(key) } && normalized[:key].to_s.match?(/\A[a-z][a-z0-9_]*\z/) && (!normalized.key?(:version) || normalized[:version].is_a?(Integer) && normalized[:version].positive?)
            validation_error!("prompt tools[#{index}] must identify a registered tool")
          end

          { key: normalized[:key].to_s, version: normalized[:version] }.freeze
        end.freeze
      end

      def validate!
        validation_error!("prompt version must be a positive integer") unless version.is_a?(Integer) && version.positive?
        %i[name description].each do |attribute|
          validation_error!("prompt #{attribute} must be a non-empty String") if public_send(attribute).empty?
        end

        placeholders = messages.flat_map { |message| message.fetch(:content).scan(PLACEHOLDER).flatten }.uniq
        validation_error!("prompt messages include undeclared inputs") unless (placeholders - inputs).empty?
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
