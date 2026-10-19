# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    # Responses API backend for hosted sessions. A conversation id (conv_) is
    # the stored session id. Turns are background responses created with
    # stream: true. The beta Agents adapter stays in OpenAIHostedAgent.
    module OpenAIResponsesAgent
      MAX_TOOL_CALLS = 4
      COMPACT_THRESHOLD = 200_000
      ACTIVE_RESPONSE_STATUSES = %w[queued in_progress].freeze
      RESPONSE_EVENT_TYPES = {
        "response.output_text.delta" => "text_delta",
        "response.output_text.done" => "message_completed"
      }.freeze
      LOCKS = {} # rubocop:disable Style/MutableConstant -- one mutex per live session id
      LOCK_GUARD = Mutex.new
      TERMINAL_EVENT_TYPES = %w[turn_completed failed cancelled].freeze
      TERMINAL_RESPONSE_EVENTS = %w[response.completed response.failed response.incomplete].freeze

      # idempotency_key stays on the run. Conversation and response creates are not
      # deduped with Idempotency-Key; that header does not apply to these endpoints.
      def responses_create_session(instructions:, model:, input:, idempotency_key:) # rubocop:disable Lint/UnusedMethodArgument
        conversation_id = nil
        started = { response_id: nil }
        hosted_request(session_lookup: false) do
          conversation_id = open_responses_conversation(model)
          response_id, sequence = open_responses_turn(
            conversation_id:, model:, instructions:, input:, started:
          )
          remember_response!(conversation_id, model, response_id, sequence)
          responses_session(conversation_id, "in_progress", model)
        rescue StandardError
          cancel_response_quietly(started[:response_id])
          delete_conversation_quietly(conversation_id)
          raise
        end
      end

      # idempotency_key stays on the run. Responses creates are not deduped with Idempotency-Key.
      def responses_submit_input(provider_session_id:, input:, idempotency_key:) # rubocop:disable Lint/UnusedMethodArgument
        with_session_lock(provider_session_id) do
          hosted_request(session_lookup: true) do
            state = responses_state(provider_session_id)
            raise_turn_active! if response_active?(state[:response])
            response_id, sequence = open_responses_turn(
              conversation_id: provider_session_id, model: state[:model],
              instructions: state[:instructions], input: input
            )
            remember_response!(provider_session_id, state[:model], response_id, sequence, state[:response_ids])
            nil
          end
        end
      end

      def responses_stream_session(provider_session_id:, &)
        state = with_session_lock(provider_session_id) { responses_state(provider_session_id) }
        missing_turn! if state[:response_id].blank?
        resume_responses(provider_session_id, state, &)
      rescue StandardError => e
        raise_hosted_failure(e, session_lookup: true, dropped: true)
      end

      def responses_cancel_turn(provider_session_id:)
        with_session_lock(provider_session_id) do
          hosted_request(session_lookup: true) do
            responses_state(provider_session_id)[:response_ids].each do |response_id|
              response = client.responses.retrieve(response_id)
              client.responses.cancel(response_id) if response_active?(response)
            end
            nil
          end
        end
      end

      # Deletes every response id stored on the conversation, then the conversation.
      # Response ids that never made it into that list, and OpenAI's own logs, remain.
      def responses_delete_session(provider_session_id:)
        with_session_lock(provider_session_id) do
          hosted_request(session_lookup: true) do
            state = responses_state(provider_session_id)
            state[:response_ids].each do |response_id|
              cancel_response_quietly(response_id)
              delete_response_quietly(response_id)
            end
            delete_conversation_quietly(provider_session_id)
            responses_session(provider_session_id, "deleted", nil)
          end
        end
      end

      def responses_recover_session(provider_session_id:, provider_turn_id: nil)
        hosted_request(session_lookup: true) do
          state = responses_state(provider_session_id)
          response_id = provider_turn_id.presence || state[:response_id]
          response = response_id.present? ? client.responses.retrieve(response_id) : nil
          HostedRecovery.new(
            session: responses_session(
              provider_session_id, read_value(response, :status).to_s.presence || "idle", state[:model]
            ),
            turn: response && responses_turn(response),
            items: responses_turn_items(response)
          )
        end
      end

      private

      def open_responses_conversation(model)
        conversation = client.conversations.create(metadata: { "model" => model.to_s })
        read_value(conversation, :id).to_s
      end

      def open_responses_turn(conversation_id:, model:, instructions:, input:, started: nil)
        params = {
          model: api_model(model),
          input: input,
          conversation: conversation_id,
          background: true,
          stream: true,
          store: true,
          max_tool_calls: MAX_TOOL_CALLS,
          context_management: [{ type: "compaction", compact_threshold: COMPACT_THRESHOLD }]
        }
        reasoning = reasoning_parameters(model, nil)
        params[:reasoning] = reasoning if reasoning
        params[:instructions] = instructions if instructions.present?
        tools = responses_mcp_tools
        params[:tools] = tools if tools.any?
        read_created_response(client.responses.stream_raw(**params), started)
      end

      def read_created_response(stream, started)
        created = nil
        sequence = nil
        stream.each do |event|
          sequence = event_sequence(event) || sequence
          next unless event_type(event) == "response.created"

          created = read_value(event, :response)
          sequence = event_sequence(event) || sequence
          started[:response_id] = read_value(created, :id).to_s if started
          break
        end
        response_id = read_value(created, :id).to_s
        missing_turn! if response_id.empty?
        [response_id, sequence]
      ensure
        stream&.close if stream.respond_to?(:close)
      end

      def remember_response!(conversation_id, model, response_id, sequence, earlier_ids = [])
        ids = (Array(earlier_ids) + [response_id.to_s]).map(&:to_s).reject(&:empty?).uniq
        metadata = {
          "model" => model.to_s,
          "response_id" => response_id.to_s,
          "response_ids" => ids.join(","),
          "sequence_number" => sequence.to_s
        }
        metadata["text_emitted"] = "false"
        client.conversations.update(conversation_id, metadata: metadata)
      end

      def responses_state(conversation_id)
        conversation = client.conversations.retrieve(conversation_id)
        response_id = metadata_value(conversation, "response_id").to_s
        response = response_id.present? ? client.responses.retrieve(response_id) : nil
        stored_model = metadata_value(conversation, "model").to_s.presence
        {
          model: stored_model || read_value(response, :model).to_s.presence,
          instructions: read_value(response, :instructions),
          response_id: response_id.presence,
          response: response,
          response_ids: responses_id_list(conversation, response_id),
          sequence: metadata_value(conversation, "sequence_number").to_s.presence,
          text_emitted: metadata_value(conversation, "text_emitted").to_s == "true",
          conversation: conversation
        }
      end

      def resume_responses(conversation_id, state, &)
        arguments = {}
        arguments[:starting_after] = state[:sequence].to_i if state[:sequence].present?
        stream = client.responses.retrieve_streaming(state[:response_id], **arguments)
        each_responses_event(stream, conversation_id, state, &)
      rescue StandardError => e
        raise unless pollable_response_error?(e)

        poll_responses(conversation_id, state, &)
      ensure
        stream&.close if stream.respond_to?(:close)
      end

      def each_responses_event(stream, conversation_id, state)
        cursor = state[:sequence].to_i
        stream.each do |event|
          sequence = event_sequence(event)
          next if sequence && sequence <= cursor

          cursor = sequence if sequence
          neutral = responses_event(event, state[:response_id])
          next unless neutral

          remember_response_chain!(conversation_id, state, neutral, cursor)
          yield neutral
          break if TERMINAL_EVENT_TYPES.include?(neutral.type)
        end
      end

      def poll_responses(conversation_id, state)
        response = nil
        5.times do
          response = client.responses.retrieve(state[:response_id])
          break unless response_active?(response)

          sleeper = @configuration&.retry_sleeper
          sleeper&.call(0)
        end
        message = nil
        unless state[:text_emitted]
          text = read_value(response, :output_text).to_s
          if text.present?
            message = responses_stream_event("message_completed", state[:response_id], { text: text })
            yield message
          end
        end
        terminal = responses_terminal_event(response, state[:response_id])
        yield terminal if terminal
        remember_response_chain!(conversation_id, state, message, state[:sequence]) if message
        remember_response_chain!(conversation_id, state, terminal, state[:sequence]) if terminal
      end

      def responses_event(event, fallback_id)
        type = event_type(event)
        response_id = response_id_from(event, fallback_id)
        mapped = RESPONSE_EVENT_TYPES[type]
        if mapped
          text = mapped == "text_delta" ? read_value(event, :delta).to_s : read_value(event, :text).to_s
          return responses_stream_event(
            mapped, response_id,
            { text_delta: mapped == "text_delta" ? text : nil, text: mapped == "message_completed" ? text : nil }
          )
        end
        return unless TERMINAL_RESPONSE_EVENTS.include?(type)

        responses_terminal_event(read_value(event, :response), response_id)
      end

      def responses_terminal_event(response, response_id)
        if approval_requests(response).any?
          return responses_failure_event(response_id, {
                                           code: "mcp_approval_required", category: "invalid_request",
                                           message: "A remote tool needs approval before this turn can finish."
                                         })
        end
        if tool_step_limit?(response)
          return responses_failure_event(response_id, {
                                           code: "tool_step_limit", category: "provider_error",
                                           message: "The hosted turn stopped at the tool step limit."
                                         })
        end

        status = read_value(response, :status).to_s
        case status
        when "failed", "incomplete"
          responses_failure_event(response_id, {
                                    code: "provider_error", category: "provider_error",
                                    message: MESSAGES.fetch("provider_error")
                                  }, response)
        when "cancelled"
          responses_failure_event(response_id, {
                                    code: "cancelled", category: "cancelled", type: "cancelled",
                                    message: MESSAGES.fetch("cancelled")
                                  }, response)
        when *ACTIVE_RESPONSE_STATUSES, ""
          nil
        else
          responses_stream_event(
            "turn_completed", response_id, { usage: normalize_usage(read_value(response, :usage)) }
          )
        end
      end

      def responses_failure_event(response_id, details, response = nil)
        error = Contracts::NormalizedError.new(
          category: details.fetch(:category), code: details.fetch(:code), message: details.fetch(:message),
          retryable: false, provider: self.class.provider_key.to_s,
          provider_code: read_value(read_value(response, :error), :code).to_s.presence
        )
        responses_stream_event(
          details.fetch(:type, "failed"), response_id,
          { error: error, usage: normalize_usage(read_value(response, :usage)) }
        )
      end

      def responses_stream_event(type, response_id, fields = {})
        StreamEvent.new(
          type: type, text_delta: fields[:text_delta], text: fields[:text], usage: fields[:usage],
          error: fields[:error],
          metadata: { provider_turn_id: response_id.to_s, provider_type: type }
        )
      end

      def remember_response_chain!(conversation_id, state, event, cursor)
        return unless event

        response_id = event.metadata["provider_turn_id"].to_s
        if response_id.present? && response_id != state[:response_id].to_s
          state[:response_id] = response_id
          state[:response_ids] = (Array(state[:response_ids]) + [response_id]).uniq
        end
        note_responses_progress(conversation_id, state, cursor, event)
      end

      def note_responses_progress(conversation_id, state, cursor, event)
        return unless event

        metadata = {
          "model" => state[:model].to_s,
          "response_id" => state[:response_id].to_s,
          "response_ids" => state[:response_ids].join(","),
          "sequence_number" => cursor.to_s,
          "text_emitted" => (state[:text_emitted] || %w[text_delta message_completed].include?(event.type)).to_s
        }
        state[:text_emitted] = metadata["text_emitted"] == "true"
        state[:sequence] = cursor.to_s
        client.conversations.update(conversation_id, metadata: metadata)
      end

      def response_id_from(event, fallback_id)
        read_value(read_value(event, :response), :id).to_s.presence || fallback_id
      end

      def responses_mcp_tools
        Array(@configuration&.hosted_agent_mcp_servers).map do |server|
          {
            type: "mcp",
            server_label: server.fetch(:server_label),
            server_url: server.fetch(:server_url),
            authorization: server[:authorization],
            headers: server[:headers],
            allowed_tools: server[:allowed_tools],
            require_approval: server[:require_approval]
          }.compact
        end
      end

      def approval_requests(response)
        Array(read_value(response, :output)).select do |item|
          read_value(item, :type).to_s == "mcp_approval_request"
        end
      end

      def tool_step_limit?(response)
        reason = read_value(read_value(response, :incomplete_details), :reason).to_s
        return true if reason == "max_tool_calls"

        tool_calls = Array(read_value(response, :output)).count do |item|
          read_value(item, :type).to_s.match?(/_call\z|tool_call/)
        end
        tool_calls > MAX_TOOL_CALLS
      end

      def responses_turn_items(response)
        Array(read_value(response, :output)).filter_map do |item|
          next unless read_value(item, :type).to_s == "message"

          text = Array(read_value(item, :content)).filter_map { |part| read_value(part, :text) }.join
          HostedItem.new(
            id: read_value(item, :id).to_s,
            role: read_value(item, :role).to_s.presence || "assistant",
            text: text,
            status: read_value(item, :status).to_s,
            provider_turn_id: read_value(response, :id).to_s.presence
          )
        end
      end

      def responses_turn(response)
        status = read_value(response, :status).to_s
        return active_responses_turn(response, status) if response_active?(response) || status.empty?

        failure = responses_terminal_event(response, read_value(response, :id))
        failed = failure&.type == "failed"
        HostedTurn.new(
          provider_turn_id: read_value(response, :id).to_s,
          status: failed ? "failed" : status,
          usage: normalize_usage(read_value(response, :usage)),
          error: failure&.error
        )
      end

      def active_responses_turn(response, status)
        HostedTurn.new(
          provider_turn_id: read_value(response, :id).to_s,
          status: status.presence || "in_progress",
          usage: nil,
          error: nil
        )
      end

      def responses_id_list(conversation, response_id)
        ids = metadata_value(conversation, "response_ids").to_s.split(",")
        ids << response_id if response_id.present?
        ids.map(&:to_s).reject(&:empty?).uniq
      end

      def responses_session(conversation_id, status, model)
        HostedSession.new(provider_session_id: conversation_id.to_s, status: status.to_s, model: model.to_s.presence)
      end

      def response_active?(response)
        ACTIVE_RESPONSE_STATUSES.include?(read_value(response, :status).to_s)
      end

      def raise_turn_active!
        raise HostedAgentFailure, Contracts::NormalizedError.new(
          category: "invalid_request", code: "turn_active",
          message: "A hosted agent turn is still running. Cancel it before sending more input.",
          retryable: false, provider: self.class.provider_key.to_s
        )
      end

      def missing_turn!
        raise HostedAgentFailure, Contracts::NormalizedError.new(
          category: "invalid_session", code: "missing_turn",
          message: MESSAGES.fetch("invalid_session"), retryable: false,
          provider: self.class.provider_key.to_s
        )
      end

      def pollable_response_error?(error)
        hosted_timeout?(error, ProviderError.status_for(error)) || hosted_network?(error)
      end

      def event_type(event)
        read_value(event, :type).to_s
      end

      def event_sequence(event)
        value = read_value(event, :sequence_number)
        return if value.nil? || value.to_s.empty?

        Integer(value)
      rescue ArgumentError
        nil
      end

      def metadata_value(record, key)
        metadata = read_value(record, :metadata)
        return if metadata.nil?

        read_value(metadata, key)
      end

      def cancel_response_quietly(response_id)
        return if response_id.blank?

        client.responses.cancel(response_id)
      rescue StandardError
        nil
      end

      def delete_response_quietly(response_id)
        return if response_id.blank?

        client.responses.delete(response_id)
      rescue StandardError
        nil
      end

      def delete_conversation_quietly(conversation_id)
        return if conversation_id.blank?

        client.conversations.delete(conversation_id)
      rescue StandardError
        nil
      end

      def with_session_lock(provider_session_id, &)
        mutex = LOCK_GUARD.synchronize { LOCKS[provider_session_id.to_s] ||= Mutex.new }
        mutex.synchronize(&)
      end
    end
  end
end
