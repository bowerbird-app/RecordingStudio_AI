# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    module RequestValidation
      PROFILES = %i[low medium high].freeze
      MESSAGE_ROLES = %w[system user assistant].freeze
      MAXIMUM_PURPOSE_LENGTH = 64

      module_function

      def validate_generation_request!(root_recording:, initiator:, prompt: nil, messages: nil, profile: nil, purpose: nil,
                                       provider: nil, model: nil, stream: false, system_instruction: nil, schema: nil,
                                       attachments: [], provider_native_tools: [], custom_tools: [], context_recording: nil,
                                       executor: nil, impersonator: nil, initiator_kind: nil,
                                       execution_source: nil, request_id: nil, job_id: nil,
                                       metadata: {}, prompt_definition: nil,
                                       temperature: nil, verbosity: nil, max_output_tokens: nil, reasoning_effort: nil,
                                       **unknown)
        reject_unknown_keys!(unknown, path: "generation request")
        profile ||= RecordingStudioAI.configuration.default_profile
        ensure_profile!(profile)
        ensure_machine_purpose!(purpose) if purpose
        ensure_attribution!(root_recording: root_recording, initiator: initiator)
        ensure_single_input_channel!(prompt: prompt, messages: messages)
        ensure_messages!(messages) if messages
        ensure_attachment_target!(attachments, messages)
        ensure_system_instruction!(system_instruction, messages)
        ensure_boolean!(stream, path: "stream")
        normalized_model = normalize_model_override!(model)
        normalized_schema = RecordingStudioAI::StructuredOutput.validate_schema!(schema)
        normalized_attachments = RecordingStudioAI::Attachments.validate!(attachments)
        normalized_provider_tools = ensure_provider_native_tools!(provider_native_tools)
        normalized_custom_tools = ensure_custom_tools!(custom_tools)
        generation_parameters = normalize_generation_parameters!(
          temperature: temperature,
          verbosity: verbosity,
          max_output_tokens: max_output_tokens,
          reasoning_effort: reasoning_effort,
          provider: provider,
          model: normalized_model
        )

        attribution = RecordingStudioAI::Contracts::Attribution.new(
          root_recording: root_recording,
          context_recording: context_recording,
          initiator: initiator,
          initiator_kind: initiator_kind,
          executor: executor,
          impersonator: impersonator,
          execution_source: execution_source,
          request_id: request_id,
          job_id: job_id
        )

        {
          prompt: prompt,
          messages: messages,
          system_instruction: system_instruction,
          profile: profile.to_sym,
          provider: provider&.to_sym,
          model: normalized_model,
          stream: stream == true,
          purpose: purpose,
          schema: normalized_schema,
          attachments: normalized_attachments,
          provider_native_tools: normalized_provider_tools,
          custom_tools: normalized_custom_tools,
          custom_tool_definitions: resolve_custom_tools!(normalized_custom_tools),
          prompt_definition: ensure_prompt_definition!(prompt_definition),
          attribution: attribution,
          metadata: RecordingStudioAI::Metadata.sanitize!(metadata, path: "metadata"),
          temperature: generation_parameters[:temperature],
          verbosity: generation_parameters[:verbosity],
          max_output_tokens: generation_parameters[:max_output_tokens],
          reasoning_effort: generation_parameters[:reasoning_effort]
        }
      end

      def validate_batch_submit_request!(items:, root_recording:, initiator:, profile: nil, provider: nil,
                                         model: nil, context_recording: nil, executor: nil, impersonator: nil,
                                         initiator_kind: nil, execution_source: nil,
                                         request_id: nil, job_id: nil, metadata: {}, **unknown)
        reject_unknown_keys!(unknown, path: "batch submission")
        profile ||= RecordingStudioAI.configuration.default_profile
        ensure_profile!(profile)
        ensure_attribution!(root_recording: root_recording, initiator: initiator)

        unless items.is_a?(Array) && !items.empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "items must be a non-empty Array",
            code: "invalid_request"
          )
        end

        normalized_items = items.map.with_index { |item, index| normalize_batch_item!(item, index) }
        duplicate_references = normalized_items.group_by { |item| item.fetch(:reference) }
                                               .select { |_reference, matches| matches.many? }
                                               .keys
        unless duplicate_references.empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "batch item references must be unique",
            code: "invalid_request"
          )
        end

        attribution = RecordingStudioAI::Contracts::Attribution.new(
          root_recording: root_recording,
          context_recording: context_recording,
          initiator: initiator,
          initiator_kind: initiator_kind,
          executor: executor,
          impersonator: impersonator,
          execution_source: execution_source,
          request_id: request_id,
          job_id: job_id
        )

        {
          items: normalized_items,
          profile: profile.to_sym,
          provider: provider&.to_sym,
          model: normalize_model_override!(model),
          attribution: attribution,
          metadata: RecordingStudioAI::Metadata.sanitize!(metadata, path: "metadata")
        }
      end

      def normalize_batch_item!(item, index)
        unless item.is_a?(Hash)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "items[#{index}] must be a Hash",
            code: "invalid_request"
          )
        end

        item = item.transform_keys(&:to_sym)
        allowed_keys = %i[
          reference prompt messages system_instruction purpose schema attachments
          provider_native_tools custom_tools metadata temperature verbosity
          max_output_tokens reasoning_effort
        ]
        reject_unknown_keys!(item.except(*allowed_keys), path: "items[#{index}]")
        unless Array(item[:custom_tools]).empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "items[#{index}] custom tools are not supported in provider batches",
            code: "invalid_request"
          )
        end

        reference = item[:reference].to_s.strip
        if reference.empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "items[#{index}].reference must be a non-empty value",
            code: "invalid_request"
          )
        end

        ensure_machine_purpose!(item[:purpose]) if item[:purpose]
        ensure_single_input_channel!(prompt: item[:prompt], messages: item[:messages])
        ensure_messages!(item[:messages]) if item[:messages]
        ensure_attachment_target!(item.fetch(:attachments, []), item[:messages])
        ensure_system_instruction!(item[:system_instruction], item[:messages])
        generation_parameters = normalize_generation_parameters!(
          temperature: item[:temperature],
          verbosity: item[:verbosity],
          max_output_tokens: item[:max_output_tokens],
          reasoning_effort: item[:reasoning_effort]
        )

        {
          reference: reference,
          prompt: item[:prompt],
          messages: item[:messages],
          system_instruction: item[:system_instruction],
          purpose: item[:purpose],
          schema: RecordingStudioAI::StructuredOutput.validate_schema!(item[:schema]),
          attachments: RecordingStudioAI::Attachments.validate!(item.fetch(:attachments, [])),
          provider_native_tools: ensure_provider_native_tools!(item.fetch(:provider_native_tools, [])),
          custom_tools: [],
          metadata: RecordingStudioAI::Metadata.sanitize!(item.fetch(:metadata, {}), path: "items[#{index}].metadata"),
          temperature: generation_parameters[:temperature],
          verbosity: generation_parameters[:verbosity],
          max_output_tokens: generation_parameters[:max_output_tokens],
          reasoning_effort: generation_parameters[:reasoning_effort]
        }
      end

      def validate_batch_lookup_request!(batch_id:, root_recording:, initiator:, context_recording: nil,
                                         executor: nil, impersonator: nil, initiator_kind: nil,
                                         execution_source: nil, request_id: nil, job_id: nil,
                                         **unknown)
        reject_unknown_keys!(unknown, path: "batch lookup")
        if batch_id.nil? || batch_id.to_s.strip.empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "batch_id is required",
            code: "invalid_request"
          )
        end

        ensure_attribution!(root_recording: root_recording, initiator: initiator)

        attribution = RecordingStudioAI::Contracts::Attribution.new(
          root_recording: root_recording,
          context_recording: context_recording,
          initiator: initiator,
          initiator_kind: initiator_kind,
          executor: executor,
          impersonator: impersonator,
          execution_source: execution_source,
          request_id: request_id,
          job_id: job_id
        )

        {
          batch_id: batch_id.to_s,
          attribution: attribution
        }
      end

      def ensure_profile!(profile)
        return if PROFILES.include?(profile.to_sym)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "profile must be one of: #{PROFILES.join(', ')}",
          code: "invalid_request"
        )
      end

      def normalize_model_override!(model)
        return nil if model.nil?

        value = model.to_s.strip
        if value.empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "model must be a non-empty String when provided",
            code: "invalid_request"
          )
        end

        value
      end

      def ensure_boolean!(value, path:)
        return if [true, false].include?(value)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{path} must be a Boolean",
          code: "invalid_request"
        )
      end

      # Normalize flat generation parameters. When provider + model are known and
      # registered, validate supported ranges/values immediately. Otherwise keep
      # type-normalized values and let the orchestrator validate against the
      # resolved candidate before calling the provider.
      def normalize_generation_parameters!(temperature: nil, verbosity: nil, max_output_tokens: nil,
                                           reasoning_effort: nil, provider: nil, model: nil)
        parameters = {
          temperature: temperature,
          verbosity: verbosity,
          max_output_tokens: max_output_tokens,
          reasoning_effort: reasoning_effort
        }
        provided = parameters.compact
        return parameters.transform_values { nil } if provided.empty?

        definition = nil
        definition = RecordingStudioAI.models.fetch(provider, model) if provider && model

        if definition
          RecordingStudioAI::Models::ParameterValidation.normalize!(definition, provided)
        else
          RecordingStudioAI::Models::ParameterValidation.normalize_without_definition!(provided)
        end
      end

      def ensure_prompt_definition!(prompt_definition)
        return nil if prompt_definition.nil?
        if prompt_definition.is_a?(RecordingStudioAI::Prompts::Definition) &&
           RecordingStudioAI.prompts.all.include?(prompt_definition)
          return prompt_definition
        end

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "prompt_definition must be a registered prompt definition",
          code: "invalid_request"
        )
      end

      def reject_unknown_keys!(unknown, path:)
        return if unknown.empty?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{path} contains unknown keys: #{unknown.keys.join(', ')}",
          code: "invalid_request"
        )
      end

      def ensure_machine_purpose!(purpose)
        return if purpose.is_a?(String) && purpose.length <= MAXIMUM_PURPOSE_LENGTH &&
                  purpose.match?(/\A[a-z0-9_]+\z/)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "purpose must be a machine-readable snake_case String of at most #{MAXIMUM_PURPOSE_LENGTH} characters",
          code: "invalid_request"
        )
      end

      def ensure_attribution!(root_recording:, initiator:)
        if root_recording.nil?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "root_recording is required",
            code: "invalid_request"
          )
        end

        return unless initiator.nil?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "initiator is required",
          code: "invalid_request"
        )
      end

      def ensure_single_input_channel!(prompt:, messages:)
        prompt_present = prompt.is_a?(String) && !prompt.strip.empty?
        messages_present = messages.is_a?(Array) && !messages.empty?

        return unless prompt_present == messages_present

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "exactly one of prompt or messages must be provided",
          code: "invalid_request"
        )
      end

      def ensure_messages!(messages)
        unless messages.is_a?(Array) && !messages.empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "messages must be a non-empty Array",
            code: "invalid_request"
          )
        end

        messages.each_with_index do |message, index|
          unless message.is_a?(Hash)
            raise RecordingStudioAI::Errors::ContractValidationError.new(
              "messages[#{index}] must be a Hash",
              code: "invalid_request"
            )
          end

          role = message[:role] || message["role"]
          content = message[:content] || message["content"]

          unless MESSAGE_ROLES.include?(role.to_s)
            raise RecordingStudioAI::Errors::ContractValidationError.new(
              "messages[#{index}].role must be one of: #{MESSAGE_ROLES.join(', ')}",
              code: "invalid_request"
            )
          end

          next if content.is_a?(String) && !content.strip.empty?

          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "messages[#{index}].content must be a non-empty String",
            code: "invalid_request"
          )
        end
      end

      def ensure_attachment_target!(attachments, messages)
        return if Array(attachments).empty? || messages.nil?
        return if messages.any? { |message| (message[:role] || message["role"]).to_s == "user" }

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "attachments require a user message",
          code: "attachment_validation"
        )
      end

      def ensure_system_instruction!(system_instruction, messages)
        return if system_instruction.nil?
        return if system_instruction.is_a?(String) && !system_instruction.strip.empty? && messages.nil?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "system_instruction must be a non-empty String and may only be used with prompt input",
          code: "invalid_request"
        )
      end

      def ensure_provider_native_tools!(tools)
        values = Array(tools).map(&:to_sym)
        unless tools.is_a?(Array) && (values - [:web_search]).empty?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "provider_native_tools supports only web_search",
            code: "invalid_request"
          )
        end
        values
      end

      def ensure_custom_tools!(tools)
        custom_tool_error!("custom_tools must be an Array") unless tools.is_a?(Array)

        tools.map.with_index do |reference, index|
          custom_tool_error!("custom_tools[#{index}] must be a Hash") unless reference.is_a?(Hash)

          normalized = reference.transform_keys(&:to_sym)
          unless normalized.keys.sort == %i[key version]
            custom_tool_error!("custom_tools[#{index}] must contain only key and version")
          end

          key = normalized[:key].to_s
          version = normalized[:version]
          valid_key = key.length <= RecordingStudioAI::Providers::ToolCall::MAX_KEY_LENGTH && key.match?(/\A[a-z0-9_]+\z/)
          unless valid_key && version.is_a?(Integer) && version.positive?
            custom_tool_error!("custom_tools[#{index}] requires a snake_case key and positive integer version")
          end

          { key: key, version: version }
        end
      end

      def resolve_custom_tools!(references)
        definitions = references.map do |reference|
          definition = RecordingStudioAI.tools.fetch(reference.fetch(:key), version: reference.fetch(:version))
          unless definition
            custom_tool_error!("unknown custom tool #{reference.fetch(:key)} version #{reference.fetch(:version)}")
          end
          definition
        end

        duplicate_keys = definitions.group_by(&:key).select { |_key, values| values.many? }.keys
        custom_tool_error!("custom_tools contains duplicate keys: #{duplicate_keys.join(', ')}") if duplicate_keys.any?
        definitions
      end

      def custom_tool_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "custom_tool_validation")
      end
    end
  end
end
