# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    HostedSession = Data.define(:provider_session_id, :status, :model)
    HostedTurn = Data.define(:provider_turn_id, :status, :usage, :error) do
      def terminal?
        %w[completed failed cancelled].include?(status.to_s)
      end
    end
    HostedItem = Data.define(:id, :role, :text, :status, :provider_turn_id)
    HostedRecovery = Data.define(:session, :turn, :items, :tool_calls) do
      def initialize(session:, turn:, items:, tool_calls: [])
        super
      end
    end

    # Provider failure already mapped to a neutral error. +dropped+ means the
    # stream ended before a terminal event; the caller must fetch saved state
    # and must not send the input again. +tool_results_rejected+ means the
    # tool-result post itself was refused with a 4xx other than 401 or 429.
    class HostedAgentFailure < StandardError
      attr_reader :error

      def initialize(error, dropped: false, tool_results_rejected: false)
        @error = error
        @dropped = dropped
        @tool_results_rejected = tool_results_rejected
        super(error.message)
      end

      def dropped?
        @dropped
      end

      def timeout?
        error.category == "timeout"
      end

      def tool_results_rejected?
        @tool_results_rejected
      end
    end
  end
end
