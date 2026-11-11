# frozen_string_literal: true

module RecordingStudioAI
  module Agents
    module Request
      ATTRIBUTION = %i[
        root_recording initiator context_recording executor impersonator
        initiator_kind execution_source request_id job_id
      ].freeze
      CREATE_KEYS = (
        %i[instructions input profile model provider idempotency_key purpose metadata tools] + ATTRIBUTION
      ).freeze
      INPUT_KEYS = (%i[session input idempotency_key purpose metadata] + ATTRIBUTION).freeze
      SESSION_KEYS = (%i[session purpose metadata] + ATTRIBUTION).freeze
      TOOL_RESULT_KEYS = (%i[results] + SESSION_KEYS).freeze
      FUNCTION_TOOL_KEYS = %w[type name description parameters defer_loading].freeze
      RESULT_KEYS = %w[call_id turn_id output error].freeze

      module_function

      def create!(**kwargs)
        build(kwargs, CREATE_KEYS, "hosted agent session") do |request|
          request[:instructions] = optional_string(kwargs[:instructions], "instructions")
          request[:input] = required_text(kwargs[:input], "input")
          request[:idempotency_key] = required_key(kwargs[:idempotency_key])
          request[:tools] = function_tools!(kwargs[:tools])
          assign_resolution!(request, kwargs)
        end
      end

      def input!(**kwargs)
        build(kwargs, INPUT_KEYS, "hosted agent input") do |request|
          request[:session] = session_record!(kwargs[:session])
          request[:input] = required_text(kwargs[:input], "input")
          request[:idempotency_key] = required_key(kwargs[:idempotency_key])
        end
      end

      def session!(**kwargs)
        record = kwargs[:session]
        build(kwargs, SESSION_KEYS, "hosted agent session") { |request| request[:session] = session_record!(record) }
      end

      def tool_results!(**kwargs)
        build(kwargs, TOOL_RESULT_KEYS, "hosted agent tool results") do |request|
          request[:session] = session_record!(kwargs[:session])
          request[:results] = tool_results(kwargs[:results])
        end
      end

      def build(kwargs, allowed, path)
        Contracts::RequestValidation.reject_unknown_keys!(kwargs.except(*allowed), path: path)
        request = shared(kwargs)
        yield request
        request
      end

      def shared(kwargs)
        purpose = kwargs[:purpose]
        Contracts::RequestValidation.ensure_machine_purpose!(purpose) if purpose
        {
          purpose: purpose,
          metadata: RecordingStudioAI::Metadata.sanitize!(kwargs.fetch(:metadata, {}), path: "metadata"),
          attribution: attribution(kwargs)
        }
      end

      def attribution(kwargs)
        Contracts::RequestValidation.attribution_from!(**kwargs.slice(*ATTRIBUTION))
      end

      def assign_resolution!(request, kwargs)
        profile = kwargs[:profile]
        Contracts::RequestValidation.ensure_profile!(profile) if profile
        request[:profile] = profile&.to_sym
        request[:model] = Contracts::RequestValidation.normalize_model_override!(kwargs[:model])
        request[:provider] = kwargs[:provider]&.to_sym
        return if request[:profile] || request[:model]

        request[:profile] = RecordingStudioAI.configuration.default_profile
      end

      def session_record!(session)
        return session if session.is_a?(Session) && !session.provider_session_id.empty?

        invalid!("session must be a RecordingStudioAI::Agents::Session")
      end

      def required_text(value, name)
        return value if value.is_a?(String) && !value.strip.empty?

        invalid!("#{name} must be a non-empty String")
      end

      def optional_string(value, name)
        return if value.nil?
        return value if value.is_a?(String)

        invalid!("#{name} must be a String")
      end

      def required_key(value)
        return value if value.is_a?(String) && !value.strip.empty? && value.length <= 255

        invalid!("idempotency_key must be a non-empty String")
      end

      def function_tools!(value)
        return if value.nil?

        invalid!("tools must be an Array of function definitions") unless value.is_a?(Array)

        value.map { |tool| function_tool!(tool) }
      end

      def function_tool!(tool)
        invalid!("a function tool must be a Hash") unless tool.is_a?(Hash)
        fields = string_fields(tool)
        unknown = fields.keys - FUNCTION_TOOL_KEYS
        invalid!("unknown function tool key: #{unknown.first}") if unknown.any?
        invalid!("function tool type must be \"function\"") unless fields["type"].to_s == "function"

        definition = {
          type: "function",
          name: function_name!(fields["name"]),
          description: function_description!(fields["description"]),
          parameters: function_parameters!(fields["parameters"])
        }
        definition.merge(defer_loading(fields))
      end

      def defer_loading(fields)
        return {} unless fields.key?("defer_loading")

        value = fields["defer_loading"]
        invalid!("defer_loading must be true or false") unless [true, false].include?(value)

        { defer_loading: value }
      end

      def function_name!(name)
        return name if name.is_a?(String) && name.match?(Agents::ToolCall::NAME_PATTERN)

        invalid!("function name must be 1-64 letters, numbers, underscores, or hyphens")
      end

      def function_description!(description)
        return description if description.is_a?(String) && !description.strip.empty?

        invalid!("function description must be a non-empty String")
      end

      def function_parameters!(parameters)
        invalid!("function parameters must be a Hash") unless parameters.is_a?(Hash)

        schema = Contracts::Containment.ensure_serializable!(parameters, path: "tools.parameters")
        return schema if schema["type"] == "object"

        invalid!("function parameters must be a JSON Schema object")
      end

      def tool_results(value)
        invalid!("results must be a non-empty Array") unless value.is_a?(Array) && !value.empty?

        value.map { |result| tool_result!(result) }
      end

      def tool_result!(result)
        invalid!("a tool result must be a Hash") unless result.is_a?(Hash)
        fields = string_fields(result)
        unknown = fields.keys - RESULT_KEYS
        invalid!("unknown tool result key: #{unknown.first}") if unknown.any?

        body = { call_id: result_id!(fields["call_id"], "call_id"), turn_id: result_id!(fields["turn_id"], "turn_id") }
        output = fields.key?("output")
        failure = fields.key?("error")
        invalid!("a tool result must include output or error") unless output ^ failure
        return body.merge(output: result_output!(fields["output"])) if output

        body.merge(error: result_error!(fields["error"]))
      end

      def result_output!(output)
        return output if output.is_a?(String)

        invalid!("tool result output must be a String")
      end

      def result_error!(message)
        return message if message.is_a?(String) && !message.strip.empty?

        invalid!("tool result error must be a non-empty String")
      end

      def result_id!(value, name)
        return value if value.is_a?(String) && !value.empty? && value.length <= Agents::ToolCall::MAX_ID_LENGTH

        invalid!("#{name} must be a non-empty String")
      end

      def string_fields(hash)
        hash.each_with_object({}) do |(key, value), fields|
          invalid!("tool fields must use String or Symbol keys") unless key.is_a?(String) || key.is_a?(Symbol)

          fields[key.to_s] = value
        end
      end

      def invalid!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
