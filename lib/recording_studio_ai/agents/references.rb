# frozen_string_literal: true

module RecordingStudioAI
  module Agents
    # Neutral handle for a provider session. Recording Studio Agents stores it.
    class Session
      attr_reader :provider, :provider_session_id, :model, :profile, :status, :run_id

      def initialize(provider:, provider_session_id:, model:, profile: nil, status: nil, run_id: nil)
        @provider = provider.to_sym
        @provider_session_id = provider_session_id.to_s
        @model = model.to_s
        @profile = profile&.to_s
        @status = status&.to_s
        @run_id = run_id
      end
    end

    # Neutral handle for one turn. Cost is calculated when read.
    class Turn
      attr_reader :provider, :provider_session_id, :provider_turn_id, :model, :status, :run_id, :usage, :error,
                  :tool_calls

      def initialize(provider:, provider_session_id:, model:, status:, run_id:, provider_turn_id: nil,
                     usage: nil, error: nil, tool_calls: [])
        @provider = provider.to_sym
        @provider_session_id = provider_session_id.to_s
        @provider_turn_id = provider_turn_id&.to_s
        @model = model.to_s
        @status = status.to_s
        @run_id = run_id
        @usage = usage
        @error = error
        @tool_calls = tool_calls
      end

      def cost
        return unless usage

        CostCalculator.estimate(usage, provider: provider, model: model)
      end
    end

    class Item
      attr_reader :id, :role, :text, :status, :provider_turn_id

      def initialize(id:, role:, text:, status:, provider_turn_id: nil)
        @id = id.to_s
        @role = role.to_s
        @text = text.to_s
        @status = status.to_s
        @provider_turn_id = provider_turn_id&.to_s
      end
    end

    # One function call the provider is waiting on. +arguments+ is the parsed
    # object, or nil when the provider payload was not a JSON object.
    # +arguments_error+ and +raw_arguments+ are set only in that case, so the
    # host can answer with +error:+. +provider_turn_id+ is the +turn_id+ to
    # send back with the result.
    class ToolCall
      NAME_PATTERN = /\A[A-Za-z0-9_-]{1,64}\z/
      MAX_ID_LENGTH = 255

      attr_reader :call_id, :name, :arguments, :provider_turn_id, :arguments_error, :raw_arguments

      def initialize(call_id:, name:, arguments:, provider_turn_id:, arguments_error: nil, raw_arguments: nil)
        @call_id = call_id.to_s
        @name = name.to_s
        @provider_turn_id = provider_turn_id.to_s
        @arguments_error = arguments_error
        @raw_arguments = raw_arguments
        @arguments = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          arguments, path: "tool_call.arguments"
        )
        validate!
      end

      def to_h
        fields = { call_id: call_id, name: name, arguments: arguments, provider_turn_id: provider_turn_id }
        return fields if arguments_error.nil?

        fields.merge(arguments_error: arguments_error, raw_arguments: raw_arguments)
      end

      private

      def validate!
        return if valid_call?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "tool call requires a call id, turn id, function name, and Hash arguments or an arguments error",
          code: "invalid_request"
        )
      end

      def valid_call?
        valid_id?(call_id) && valid_id?(provider_turn_id) && name.match?(NAME_PATTERN) && valid_arguments?
      end

      def valid_arguments?
        return arguments.is_a?(Hash) if arguments_error.nil? && raw_arguments.nil?

        arguments.nil? && arguments_error.is_a?(String) && !arguments_error.strip.empty? && raw_arguments.is_a?(String)
      end

      def valid_id?(value)
        !value.empty? && value.length <= MAX_ID_LENGTH
      end
    end

    class Recovery
      attr_reader :session, :turn, :items, :tool_calls

      def initialize(session:, turn:, items:, tool_calls: [])
        @session = session
        @turn = turn
        @items = items
        @tool_calls = tool_calls
      end
    end

    class Failure < StandardError
      attr_reader :error

      def initialize(error)
        @error = error
        super(error.message)
      end
    end
  end
end
