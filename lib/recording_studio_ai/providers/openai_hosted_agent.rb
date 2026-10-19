# frozen_string_literal: true

require_relative "openai_responses_agent"

module RecordingStudioAI
  module Providers
    # OpenAI hosted sessions. The default backend is the beta Agents API.
    # config.hosted_agent_backend chooses the API for new sessions only.
    # A stored sess_ id always uses the beta adapter. A stored conv_ id always
    # uses Responses. Any other stored id raises legacy_beta_session.
    # Hosted sessions are stored on OpenAI and are not Zero Data Retention
    # eligible. Responses generation still sends store: false.
    module OpenAIHostedAgent
      include OpenAIResponsesAgent

      ENVIRONMENT = { type: "none" }.freeze
      EVENT_TYPES = {
        "agent.session.turn.output_text.delta" => "text_delta",
        "agent.session.turn.output_text.done" => "message_completed",
        "agent.session.turn.completed" => "turn_completed",
        "agent.session.turn.failed" => "failed",
        "agent.session.turn.cancelled" => "cancelled",
        "agent.session.failed" => "failed",
        "agent.session.environment.failed" => "failed",
        "error" => "failed"
      }.freeze
      TERMINAL_EVENT_TYPES = %w[turn_completed failed cancelled].freeze
      MESSAGES = {
        "authentication" => "Provider authentication failed.",
        "unsupported_model" => "Provider model is not supported for hosted agents.",
        "rate_limit" => "Provider rate limit exceeded.",
        "timeout" => "Provider request timed out.",
        "connection" => "Provider connection failed.",
        "invalid_session" => "Hosted agent session is invalid or expired.",
        "provider_unavailable" => "Provider is unavailable.",
        "cancelled" => "Hosted agent turn was cancelled.",
        "provider_error" => "Provider request failed."
      }.freeze

      def create_hosted_agent_session(instructions:, model:, input:, idempotency_key:)
        return responses_create_session(instructions:, model:, input:, idempotency_key:) if responses_backend?

        beta_create_session(instructions:, model:, input:, idempotency_key:)
      end

      def beta_create_session(instructions:, model:, input:, idempotency_key:)
        response = hosted_request(session_lookup: false) do
          client.beta.agents.sessions.create(
            **session_create_params(instructions, model, input, idempotency_key)
          )
        end
        hosted_session(response)
      end

      def submit_hosted_agent_input(provider_session_id:, input:, idempotency_key:)
        if responses_session?(provider_session_id)
          return responses_submit_input(provider_session_id:, input:,
                                        idempotency_key:)
        end

        beta_submit_input(provider_session_id:, input:, idempotency_key:)
      end

      def beta_submit_input(provider_session_id:, input:, idempotency_key:)
        hosted_request(session_lookup: true) do
          client.beta.agents.sessions.events.create(
            provider_session_id,
            idempotency_key: idempotency_key,
            events: [message_input(input)]
          )
        end
        nil
      end

      def stream_hosted_agent_session(provider_session_id:, &)
        return responses_stream_session(provider_session_id:, &) if responses_session?(provider_session_id)

        beta_stream_session(provider_session_id:, &)
      end

      def beta_stream_session(provider_session_id:, &)
        stream = client.beta.agents.sessions.events.stream_streaming(provider_session_id)
        each_hosted_event(stream, &)
      rescue StandardError => e
        raise_hosted_failure(e, session_lookup: true, dropped: true)
      ensure
        stream&.close if stream.respond_to?(:close)
      end

      def cancel_hosted_agent_turn(provider_session_id:)
        return responses_cancel_turn(provider_session_id:) if responses_session?(provider_session_id)

        beta_cancel_turn(provider_session_id:)
      end

      def beta_cancel_turn(provider_session_id:)
        hosted_request(session_lookup: true) do
          client.beta.agents.sessions.events.create(
            provider_session_id,
            events: [{ type: "agent.session.input.cancel" }]
          )
        end
        nil
      end

      def delete_hosted_agent_session(provider_session_id:)
        return responses_delete_session(provider_session_id:) if responses_session?(provider_session_id)

        beta_delete_session(provider_session_id:)
      end

      def beta_delete_session(provider_session_id:)
        hosted_request(session_lookup: true) do
          client.beta.agents.sessions.delete(provider_session_id)
        end
        HostedSession.new(provider_session_id: provider_session_id.to_s, status: "deleted", model: nil)
      end

      def recover_hosted_agent_session(provider_session_id:, provider_turn_id: nil)
        if responses_session?(provider_session_id)
          return responses_recover_session(provider_session_id:,
                                           provider_turn_id:)
        end

        beta_recover_session(provider_session_id:, provider_turn_id:)
      end

      def beta_recover_session(provider_session_id:, provider_turn_id: nil)
        hosted_request(session_lookup: true) do
          session = client.beta.agents.sessions.retrieve(provider_session_id)
          turn = fetch_hosted_turn(provider_session_id, provider_turn_id)
          HostedRecovery.new(
            session: hosted_session(session),
            turn: turn && hosted_turn(turn),
            items: fetch_hosted_items(provider_session_id)
          )
        end
      end

      private :beta_create_session, :beta_submit_input, :beta_stream_session,
              :beta_cancel_turn, :beta_delete_session, :beta_recover_session

      private

      def responses_backend?
        @configuration&.hosted_agent_backend&.to_sym == :responses
      end

      def responses_session?(provider_session_id)
        backend_for(provider_session_id) == :responses
      end

      def backend_for(provider_session_id)
        session_id = provider_session_id.to_s
        return :responses if session_id.start_with?("conv_")
        return :agents_beta if session_id.start_with?("sess_")

        legacy_beta_session!
      end

      def legacy_beta_session!
        raise HostedAgentFailure, Contracts::NormalizedError.new(
          category: "invalid_session",
          code: "legacy_beta_session",
          message: "This session id is neither a beta session (sess_) nor a Responses conversation (conv_).",
          retryable: false,
          provider: self.class.provider_key.to_s
        )
      end

      def session_create_params(instructions, model, input, idempotency_key)
        params = {
          agent: { model: model, instructions: instructions }.compact,
          environment: ENVIRONMENT,
          input: input
        }
        # Session create has no typed idempotency field. The header is the
        # provider's idempotency key. Follow-up input uses events.create.
        params[:request_options] = { extra_headers: { "idempotency-key" => idempotency_key } } if idempotency_key
        params
      end

      def message_input(input)
        {
          type: "agent.session.input.message",
          input: [{ role: "user", content: [{ type: "input_text", text: input }] }]
        }
      end

      def each_hosted_event(stream)
        stream.each do |event|
          neutral = normalize_hosted_event(event)
          next unless neutral

          yield neutral
          break if TERMINAL_EVENT_TYPES.include?(neutral.type)
        end
      end

      def hosted_request(session_lookup:)
        yield
      rescue StandardError => e
        raise_hosted_failure(e, session_lookup: session_lookup, dropped: false)
      end

      def raise_hosted_failure(error, session_lookup:, dropped:)
        raise error unless ProviderError.expected?(error)

        mapped = map_hosted_error(error, session_lookup: session_lookup)
        raise HostedAgentFailure.new(mapped, dropped: dropped && mapped.category == "connection")
      end

      def map_hosted_error(error, session_lookup:)
        status = ProviderError.status_for(error)
        code = ProviderError.provider_code(error, status).to_s
        category, retryable = hosted_category(error, status, code, session_lookup)
        Contracts::NormalizedError.new(
          category: category,
          code: hosted_error_code(category, status, code),
          message: MESSAGES.fetch(category),
          retryable: retryable,
          provider: self.class.provider_key.to_s,
          provider_code: code.empty? ? status&.to_s : code
        )
      end

      def hosted_category(error, status, code, session_lookup)
        return ["timeout", true] if hosted_timeout?(error, status)
        return ["connection", true] if hosted_network?(error)
        return ["authentication", false] if status == 401
        return ["rate_limit", true] if status == 429 || code.match?(/rate_limit/i)
        return ["unsupported_model", false] if unsupported_hosted_model?(status, code)
        return ["invalid_session", false] if invalid_hosted_session?(status, code, session_lookup)
        return ["provider_unavailable", true] if status && status >= 500

        ["provider_error", false]
      end

      def hosted_timeout?(error, status)
        error.is_a?(Timeout::Error) || status == 408 || error.class.name.end_with?("TimeoutError")
      end

      def hosted_network?(error)
        error.is_a?(SocketError) || error.is_a?(SystemCallError) || error.class.name.end_with?("ConnectionError")
      end

      def unsupported_hosted_model?(status, code)
        [400, 404].include?(status) && code.match?(/model/i)
      end

      def invalid_hosted_session?(status, code, session_lookup)
        code.match?(/session|expired/i) || (session_lookup && status == 404 && !code.match?(/model/i))
      end

      def hosted_error_code(category, status, code)
        return "invalid_credentials" if category == "authentication"
        return "network" if category == "connection"
        return code unless code.empty?

        status ? "http_#{status}" : category
      end

      def hosted_session(response)
        agent = read_value(response, :agent)
        HostedSession.new(
          provider_session_id: read_value(response, :id).to_s,
          status: read_value(response, :status).to_s,
          model: read_value(agent, :model).to_s.presence
        )
      end

      def fetch_hosted_turn(provider_session_id, provider_turn_id)
        turns = client.beta.agents.sessions.turns
        return turns.retrieve(provider_turn_id, session_id: provider_session_id) if provider_turn_id

        page = turns.list(provider_session_id, order: "desc", limit: 1)
        Array(read_value(page, :data)).first
      end

      def fetch_hosted_items(provider_session_id)
        page = client.beta.agents.sessions.items.list(provider_session_id, order: "asc", limit: 100)
        collect_pages(page).filter_map { |item| hosted_item(item) }
      end

      def collect_pages(page)
        rows = []
        20.times do
          break unless page

          rows.concat(Array(read_value(page, :data)))
          page = page.respond_to?(:next_page?) && page.next_page? ? page.next_page : nil
        end
        rows
      end

      def hosted_turn(turn)
        status = read_value(turn, :status).to_s
        HostedTurn.new(
          provider_turn_id: read_value(turn, :id).to_s,
          status: status,
          usage: normalize_usage(read_value(turn, :usage)),
          error: hosted_turn_error(turn, status)
        )
      end

      def hosted_turn_error(turn, status)
        return unless %w[failed cancelled expired].include?(status)

        code = read_value(read_value(turn, :error), :code).to_s
        category = status == "cancelled" ? "cancelled" : session_failure_category(code)
        Contracts::NormalizedError.new(
          category: category,
          code: code.empty? ? status : code,
          message: MESSAGES.fetch(category),
          retryable: false,
          provider: self.class.provider_key.to_s,
          provider_code: code.presence
        )
      end

      def session_failure_category(code)
        return "invalid_session" if code.match?(/session|expired/i)
        return "unsupported_model" if code.match?(/model/i)
        return "rate_limit" if code.match?(/rate_limit/i)

        "provider_error"
      end

      def hosted_item(item)
        text = hosted_item_text(item)
        HostedItem.new(
          id: read_value(item, :id).to_s,
          role: read_value(item, :role).to_s.presence || read_value(item, :type).to_s,
          text: text,
          status: read_value(item, :status).to_s,
          provider_turn_id: read_value(item, :turn_id).to_s.presence
        )
      end

      def hosted_item_text(item)
        content = read_value(item, :content)
        return read_value(item, :text).to_s if content.nil?

        Array(content).filter_map { |part| read_value(part, :text) }.join
      end

      def normalize_hosted_event(event)
        return if subagent_event?(event)

        neutral = EVENT_TYPES[read_value(event, :type).to_s]
        return unless neutral

        build_hosted_event(event, neutral)
      end

      def subagent_event?(event)
        turn = read_value(event, :turn)
        subagent = read_value(event, :subagent_id) || read_value(turn, :subagent_id)
        !subagent.nil? && !subagent.to_s.empty?
      end

      def build_hosted_event(event, neutral)
        StreamEvent.new(
          type: neutral,
          text_delta: neutral == "text_delta" ? read_value(event, :delta).to_s : nil,
          text: neutral == "message_completed" ? read_value(event, :text).to_s : nil,
          usage: neutral == "turn_completed" ? hosted_event_usage(event) : nil,
          error: hosted_event_error(event, neutral),
          metadata: hosted_event_metadata(event)
        )
      end

      def hosted_event_usage(event)
        raw = read_value(event, :usage) || read_value(read_value(event, :turn), :usage)
        normalize_usage(raw)
      end

      def hosted_event_error(event, neutral)
        return unless %w[failed cancelled].include?(neutral)

        code = hosted_event_code(event)
        category = neutral == "cancelled" ? "cancelled" : session_failure_category(code)
        Contracts::NormalizedError.new(
          category: category,
          code: code.empty? ? neutral : code,
          message: MESSAGES.fetch(category),
          retryable: false,
          provider: self.class.provider_key.to_s,
          provider_code: code.presence
        )
      end

      def hosted_event_code(event)
        turn = read_value(event, :turn)
        err = read_value(event, :error) || read_value(turn, :error)
        read_value(err, :code).to_s
      end

      def hosted_event_metadata(event)
        turn = read_value(event, :turn)
        {
          provider_type: read_value(event, :type).to_s,
          provider_turn_id: read_value(event, :turn_id).presence || read_value(turn, :id),
          item_id: read_value(event, :item_id),
          output_index: read_value(event, :output_index),
          content_index: read_value(event, :content_index)
        }.compact
      end
    end
  end
end
