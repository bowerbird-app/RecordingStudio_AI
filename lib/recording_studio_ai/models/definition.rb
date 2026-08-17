# frozen_string_literal: true

module RecordingStudioAI
  module Models
    # Metadata describing a single provider model. Definitions are declarative:
    # each built-in model ships as a registration script under
    # lib/recording_studio_ai/models/<provider>/<key>.rb and host apps may
    # register their own. The definition captures delivery modes, tunable
    # parameters, native tools, and modalities so downstream consumers (the
    # resolver, request validation, and the AI playground) can reason about
    # what a model supports without hard-coding capability arrays in profiles.
    class Definition
      KEY_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

      DELIVERY_KEYS = %i[streaming structured_output batch batch_cancellation].freeze

      KNOWN_PARAMETERS = %i[temperature verbosity max_output_tokens reasoning_effort].freeze
      PARAMETER_KEYS = %i[supported min max default step values].freeze

      TOOLS = %i[web_search file_search code_execution image_generation custom_tools].freeze

      MODALITIES = %i[text image audio video file].freeze

      attr_reader :provider, :key, :model, :display_name, :delivery, :parameters, :tools, :modalities, :metadata

      def initialize(provider:, key:, model:, display_name: nil, delivery: {}, parameters: {}, tools: [],
                     modalities: {}, metadata: {})
        @provider = normalize_provider(provider)
        @key = normalize_key(key)
        @model = normalize_model(model)
        @display_name = display_name.to_s.strip.presence || @key.tr("-", " ").split.map(&:capitalize).join(" ")
        @delivery = normalize_delivery(delivery)
        @parameters = normalize_parameters(parameters)
        @tools = normalize_tools(tools)
        @modalities = normalize_modalities(modalities)
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "model.metadata")

        freeze
      end

      # Translate the declarative definition into the internal capability
      # symbols the resolver uses to match candidates against a request.
      def capabilities
        capabilities = [:generation]
        capabilities << :streaming if delivery[:streaming]
        capabilities << :structured_output if delivery[:structured_output]
        capabilities << :provider_batch if delivery[:batch]
        capabilities << :provider_batch_cancellation if delivery[:batch_cancellation]
        capabilities << :image_input if modalities[:input].include?(:image)
        capabilities << :file_input if modalities[:input].include?(:file)
        capabilities << :provider_native_web_search if tools.include?(:web_search)
        capabilities << :custom_tools if tools.include?(:custom_tools)
        capabilities.uniq.freeze
      end

      def parameter(name)
        parameters[name.to_sym]
      end

      def supports_parameter?(name)
        spec = parameter(name)
        spec ? spec.fetch(:supported, false) : false
      end

      def supports_tool?(tool)
        tools.include?(tool.to_sym)
      end

      def to_h
        {
          provider: provider,
          key: key,
          model: model,
          display_name: display_name,
          delivery: delivery,
          parameters: parameters,
          tools: tools,
          modalities: modalities,
          capabilities: capabilities,
          metadata: metadata
        }
      end

      private

      def normalize_provider(value)
        provider = value.to_s
        validation_error!("model provider is required") if provider.empty?

        provider.to_sym
      end

      def normalize_key(value)
        key = value.to_s
        unless key.match?(KEY_FORMAT)
          validation_error!("model key must be a lowercase hyphenated slug (got #{value.inspect})")
        end

        key
      end

      def normalize_model(value)
        model = value.to_s.strip
        validation_error!("model identifier is required") if model.empty?

        model
      end

      def normalize_delivery(value)
        validation_error!("model delivery must be a Hash") unless value.is_a?(Hash)

        delivery = value.transform_keys(&:to_sym)
        unknown = delivery.keys - DELIVERY_KEYS
        validation_error!("unknown delivery keys: #{unknown.join(', ')}") if unknown.any?

        DELIVERY_KEYS.to_h { |delivery_key| [delivery_key, delivery.fetch(delivery_key, false) == true] }.freeze
      end

      def normalize_parameters(value)
        validation_error!("model parameters must be a Hash") unless value.is_a?(Hash)

        value.each_with_object({}) do |(name, spec), normalized|
          parameter_name = name.to_sym
          unless KNOWN_PARAMETERS.include?(parameter_name)
            validation_error!("unknown model parameter: #{parameter_name} (known: #{KNOWN_PARAMETERS.join(', ')})")
          end
          normalized[parameter_name] = normalize_parameter_spec(parameter_name, spec)
        end.freeze
      end

      def normalize_parameter_spec(name, spec)
        validation_error!("model parameter #{name} must be a Hash") unless spec.is_a?(Hash)

        symbolized = spec.transform_keys(&:to_sym)
        unknown = symbolized.keys - PARAMETER_KEYS
        validation_error!("unknown keys for parameter #{name}: #{unknown.join(', ')}") if unknown.any?

        supported = symbolized.fetch(:supported, true) == true
        values = symbolized[:values]
        validation_error!("model parameter #{name} values must be an Array") if values && !values.is_a?(Array)

        {
          supported: supported,
          min: symbolized[:min],
          max: symbolized[:max],
          default: symbolized[:default],
          step: symbolized[:step],
          values: values ? values.dup.freeze : nil
        }.compact.freeze
      end

      def normalize_tools(value)
        tools = Array(value).map(&:to_sym).uniq
        unknown = tools - TOOLS
        validation_error!("unknown model tools: #{unknown.join(', ')} (known: #{TOOLS.join(', ')})") if unknown.any?

        tools.freeze
      end

      def normalize_modalities(value)
        validation_error!("model modalities must be a Hash") unless value.is_a?(Hash)

        modalities = value.transform_keys(&:to_sym)
        unknown_sections = modalities.keys - %i[input output]
        validation_error!("unknown modality sections: #{unknown_sections.join(', ')}") if unknown_sections.any?

        {
          input: normalize_modality_list(modalities.fetch(:input, [])),
          output: normalize_modality_list(modalities.fetch(:output, []))
        }.freeze
      end

      def normalize_modality_list(value)
        list = Array(value).map(&:to_sym).uniq
        unknown = list - MODALITIES
        validation_error!("unknown modalities: #{unknown.join(', ')} (known: #{MODALITIES.join(', ')})") if unknown.any?

        list.freeze
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
