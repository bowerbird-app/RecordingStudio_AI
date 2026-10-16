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
      attr_reader :provider, :provider_session_id, :provider_turn_id, :model, :status, :run_id, :usage, :error

      def initialize(provider:, provider_session_id:, model:, status:, run_id:, provider_turn_id: nil,
                     usage: nil, error: nil)
        @provider = provider.to_sym
        @provider_session_id = provider_session_id.to_s
        @provider_turn_id = provider_turn_id&.to_s
        @model = model.to_s
        @status = status.to_s
        @run_id = run_id
        @usage = usage
        @error = error
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

    class Recovery
      attr_reader :session, :turn, :items

      def initialize(session:, turn:, items:)
        @session = session
        @turn = turn
        @items = items
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
