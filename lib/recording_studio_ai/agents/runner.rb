# frozen_string_literal: true

module RecordingStudioAI
  module Agents
    class Runner
      TERMINAL_EVENTS = %w[turn_completed failed cancelled].freeze
      STATUS_FOR_EVENT = {
        "turn_completed" => "completed",
        "failed" => "failed",
        "cancelled" => "cancelled"
      }.freeze

      STREAMING_KEY = :recording_studio_ai_hosted_agent_streaming
      SUBMITTED_CALLS_KEY = "submitted_tool_call_ids"

      # Fiber-local. The block form sets it on the caller's fiber. An external
      # Enumerator runs in its own fiber, so abandoning stream(...).next does
      # not leave the guard set on a pooled thread. That form is not guarded.
      def self.streaming?
        Thread.current[STREAMING_KEY] == true
      end

      def create(raw)
        request = Request.create!(**raw)
        authorize!(request)
        candidate = Resolution.call(profile: request[:profile], model: request[:model], provider: request[:provider])
        run = insert_run(request, candidate, request[:input])
        ensure_credits!(request.fetch(:attribution), run)
        hosted = call_provider(run) do
          adapter_for(candidate.provider).create_hosted_agent_session(
            instructions: request[:instructions], model: candidate.model,
            input: request[:input], idempotency_key: request[:idempotency_key],
            tools: request[:tools]
          )
        end
        remember_session(run, hosted)
        session_from(run, hosted, request[:profile])
      end

      def send_input(raw)
        request = Request.input!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = run_for_input(session, request)
        ensure_credits!(request.fetch(:attribution), run)
        call_provider(run) do
          adapter_for(session.provider).submit_hosted_agent_input(
            provider_session_id: session.provider_session_id,
            input: request[:input], idempotency_key: request[:idempotency_key]
          )
        end
        turn_from(run.reload)
      end

      def stream(raw, &)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = running_run(session, request) || latest_run(session, request)
        return recovered_turn(session, run, &) if settled_snapshot?(session, run)

        watch(session, run, &)
      end

      def cancel(raw)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = running_run(session, request)
        call_provider(nil) do
          adapter_for(session.provider).cancel_hosted_agent_turn(provider_session_id: session.provider_session_id)
        end
        cancel_run(run, usage_after_cancel(session, run))
        replace_status(session, "cancelled")
      end

      def delete_session(raw)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        call_provider(nil) do
          adapter_for(session.provider).delete_hosted_agent_session(provider_session_id: session.provider_session_id)
        end
        replace_status(session, "deleted")
      end

      def submit_tool_results(raw, &)
        request = Request.tool_results!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = running_run(session, request) || latest_run(session, request)
        results = request.fetch(:results)
        claim_pending_results!(session, run, results)
        continue_stream(session, run, results, &)
      end

      def recover(raw)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = running_run(session, request) || latest_run(session, request)
        snapshot = fetch_recovery(session, run)
        apply_recovery(run, snapshot)
        recovery_from(session, run, snapshot)
      end

      private

      def authorize!(request)
        Authorization.authorize!(
          :execute, attribution: request.fetch(:attribution), context: { operation: "hosted_agent" }
        )
      end

      # The handle is not proof of ownership. Allow the call only when every
      # hosted_agent run for this provider session belongs to the caller's root.
      def guard_session!(session, request)
        root_id = Orchestration::Support.identifier(request.fetch(:attribution).root_recording)
        runs = RecordingStudioAI::Run.where(
          operation: "hosted_agent", provider_session_id: session.provider_session_id
        )
        return if runs.where(root_recording_id: root_id).exists? && runs.where.not(root_recording_id: root_id).none?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "Not authorized for action #{Authorization::ACTIONS.fetch(:execute)}",
          code: "authorization"
        )
      end

      def watch(session, run, &block)
        ensure_credits!(attribution_for(run), run)
        consume(session, run, block) do |on_event|
          adapter_for(session.provider).stream_hosted_agent_session(
            provider_session_id: session.provider_session_id, &on_event
          )
        end
      end

      def continue_stream(session, run, results, &block)
        ensure_credits!(attribution_for(run), run)
        consume(session, run, block, reject_provider_failure: true, submitted_results: results) do |on_event|
          adapter_for(session.provider).continue_hosted_agent_after_tool_results(
            provider_session_id: session.provider_session_id, results: results, &on_event
          )
        end
      end

      def consume(session, run, handler, reject_provider_failure: false, submitted_results: nil)
        finished = false
        pending = nil
        streaming do
          yield proc { |event|
            finished = true if observe(run, event)
            pending = event.tool_calls if event.type == "tool_calls"
            handler.call(event)
          }
        end
        return turn_from(run&.reload) if finished
        return turn_from(run&.reload, tool_calls: pending) if pending

        recovered_turn(session, run, &handler)
      rescue Providers::HostedAgentFailure => e
        release_still_pending_calls!(session, run, submitted_results) if submitted_results
        raise Failure, e.error if e.timeout?
        return recovered_turn(session, run, &handler) if e.dropped?

        if reject_provider_failure
          invalid_results!("hosted agent rejected the tool results") if e.tool_results_rejected?

          raise Failure, e.error
        end

        fail_and_raise(run, e)
      end

      def streaming
        previous = Thread.current[STREAMING_KEY]
        Thread.current[STREAMING_KEY] = true
        yield
      ensure
        Thread.current[STREAMING_KEY] = previous
      end

      def recovered_turn(session, run, &block)
        snapshot = fetch_recovery(session, run)
        apply_recovery(run, snapshot)
        calls = Array(snapshot.tool_calls)
        streaming do
          Array(snapshot.items).each { |item| block.call(item_event(item)) if replay_item?(item) }
          if calls.any?
            block.call(tool_calls_event(calls))
          elsif snapshot.turn&.terminal?
            block.call(turn_event(snapshot.turn))
          end
        end
        return turn_from(run&.reload, snapshot.turn, session, tool_calls: calls) if calls.any?

        turn_from(run&.reload, snapshot.turn, session)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?

        fail_and_raise(run, e)
      end

      # A finished turn can be replayed. A turn that is already waiting on the
      # caller must be reported from the session, because a new event stream does
      # not repeat requires_action.
      def settled_snapshot?(session, run)
        snapshot = fetch_recovery(session, run)
        snapshot.turn&.terminal? || Array(snapshot.tool_calls).any?
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?

        false
      end

      def fetch_recovery(session, run)
        adapter_for(session.provider).recover_hosted_agent_session(
          provider_session_id: session.provider_session_id,
          provider_turn_id: run&.provider_turn_id
        )
      end

      def observe(run, event) # rubocop:disable Naming/PredicateMethod -- records the event, then reports whether it ended the turn
        return false unless run

        remember_turn(run, event.metadata["provider_turn_id"])
        return false unless TERMINAL_EVENTS.include?(event.type)

        finish_run(run, STATUS_FOR_EVENT.fetch(event.type), event.usage, event.error, event.text)
        true
      end

      def apply_recovery(run, snapshot)
        return unless run && snapshot.turn

        remember_turn(run, snapshot.turn.provider_turn_id)
        return if Array(snapshot.tool_calls).any?
        return unless snapshot.turn.terminal?

        text = Array(snapshot.items).map(&:text).join
        finish_run(run, snapshot.turn.status, snapshot.turn.usage, snapshot.turn.error, text)
      end

      def finish_run(run, status, usage, error, text)
        return if run.class.terminal_statuses.include?(run.status)

        assign_usage(run, usage)
        charge(run, usage)
        run.update!(terminal_attributes(run, status, error, text))
      end

      def assign_usage(run, usage)
        return unless usage
        return if turn_charged?(run.provider_turn_id, run.id)

        run.update!(
          input_tokens: usage.input_tokens, output_tokens: usage.output_tokens, total_tokens: usage.total_tokens,
          cached_input_tokens: usage.cached_input_tokens, reasoning_tokens: usage.reasoning_tokens
        )
      end

      def charge(run, usage)
        return if run.provider_turn_id.blank?
        return if turn_charged?(run.provider_turn_id, nil)
        return unless Usage.charge_hosted_agent_turn!(run: run, usage: usage, attribution: attribution_for(run))

        run.update!(metadata: metadata_with(run, "usage_charged" => true))
      end

      def ensure_credits!(attribution, run)
        Usage.precheck!(attribution: attribution)
      rescue StandardError => e
        refuse_run!(run, e)
        raise
      end

      def refuse_run!(run, error)
        return if run.nil? || run.class.terminal_statuses.include?(run.status)

        run.update!(
          status: "failed",
          error_category: Usage::DECLINED_CATEGORY,
          error_code: Usage::DECLINED_CODE,
          error_message: error.message.to_s[0, Usage::MESSAGE_LIMIT],
          completed_at: Time.current
        )
      rescue StandardError
        nil
      end

      def turn_charged?(turn_id, except_id)
        return false if turn_id.blank?

        scope = RecordingStudioAI::Run.where(provider_turn_id: turn_id)
        scope = scope.where.not(id: except_id) if except_id
        scope.any? { |record| record.metadata.to_h["usage_charged"] == true }
      end

      def call_provider(run)
        yield
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?

        fail_and_raise(run, e)
      end

      def fail_and_raise(run, failure)
        fail_run(run, failure.error) if run && !failure.dropped?
        raise Failure, failure.error
      end

      def fail_run(run, error)
        return if run.class.terminal_statuses.include?(run.status)

        run.update!(terminal_attributes(run, "failed", error, nil))
      end

      # The provider cancel has already been accepted. Usage on a turn is
      # best-effort and may be null, including after cancellation. Bill only
      # what this read reports. A provider failure leaves the run cancelled.
      # Any other error is raised.
      def usage_after_cancel(session, run)
        return if run.nil? || terminal_run?(run)

        fetch_recovery(session, run)
      rescue Providers::HostedAgentFailure => e
        log_cancel_usage_failure(run, e)
        nil
      end

      def log_cancel_usage_failure(run, error)
        Rails.logger.warn(
          "recording_studio_ai cancel usage fetch failed run_id=#{run.id} error=#{error.class}"
        )
      end

      def cancel_run(run, snapshot = nil)
        return if run.nil? || terminal_run?(run)

        remember_turn(run, snapshot&.turn&.provider_turn_id)
        finish_run(run, "cancelled", snapshot&.turn&.usage, cancelled_error, nil)
      end

      def cancelled_error
        Contracts::NormalizedError.new(
          category: "cancelled", code: "cancelled", message: "Hosted agent turn was cancelled.", retryable: false
        )
      end

      def release_paused_run(session, run)
        call_provider(nil) do
          adapter_for(session.provider).cancel_hosted_agent_turn(provider_session_id: session.provider_session_id)
        end
        cancel_run(run, usage_after_cancel(session, run))
      end

      # The provider read stays outside the row lock. The lock re-checks the
      # run and records the call ids.
      def claim_pending_results!(session, run, results)
        invalid_results!("hosted agent turn is not waiting on tool results") if run.nil? || terminal_run?(run)

        pending = pending_tool_calls(session, run)
        run.with_lock do
          invalid_results!("hosted agent turn is not waiting on tool results") if terminal_run?(run) || pending.empty?

          match_pending_results!(pending, results)
          reject_claimed_calls!(run, results)
          remember_submitted_calls!(run, results)
        end
      end

      # A rejected, timed-out, or unsent post must not stick. Forget the claimed
      # ids the provider still lists. A failed reread leaves them claimed.
      def release_still_pending_calls!(session, run, results)
        return if run.nil? || results.empty?

        pending_ids = still_pending_call_ids(session, run)
        return if pending_ids.nil?

        releasing = results.map { |result| result[:call_id].to_s } & pending_ids
        return if releasing.empty?

        run.with_lock do
          kept = submitted_call_ids(run) - releasing
          run.update!(metadata: metadata_with(run, SUBMITTED_CALLS_KEY => kept))
        end
      end

      def still_pending_call_ids(session, run)
        snapshot = fetch_recovery(session, run)
        return [] if snapshot.turn&.terminal?

        Array(snapshot.tool_calls).map { |call| call.call_id.to_s }
      rescue Providers::HostedAgentFailure
        nil
      end

      def reject_claimed_calls!(run, results)
        claimed = submitted_call_ids(run)
        results.each do |result|
          next unless claimed.include?(result[:call_id])

          invalid_results!("tool result call_id was already submitted: #{result[:call_id]}")
        end
      end

      def remember_submitted_calls!(run, results)
        ids = submitted_call_ids(run) + results.map { |result| result[:call_id] }
        run.update!(metadata: metadata_with(run, SUBMITTED_CALLS_KEY => ids.uniq))
      end

      def submitted_call_ids(run)
        Array(run.metadata.to_h[SUBMITTED_CALLS_KEY]).map(&:to_s)
      end

      def pending_tool_calls(session, run)
        snapshot = fetch_recovery(session, run)
        return [] if snapshot.turn&.terminal?

        Array(snapshot.tool_calls)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error
      end

      def match_pending_results!(pending, results)
        by_id = pending.index_by(&:call_id)
        seen = {}
        results.each do |result|
          call_id = result[:call_id]
          invalid_results!("duplicate tool result call_id: #{call_id}") if seen[call_id]
          seen[call_id] = true
          call = by_id[call_id]
          invalid_results!("unknown tool result call_id: #{call_id}") unless call
          next if result[:turn_id] == call.provider_turn_id

          invalid_results!("tool result turn_id does not match call #{call_id}")
        end
      end

      def invalid_results!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end

      def terminal_run?(run)
        run.class.terminal_statuses.include?(run.status)
      end

      def terminal_attributes(run, status, error, text)
        completed_at = Time.current
        {
          status: status,
          output_character_count: text&.length,
          **Orchestration::Support.completion_clock(run.started_at, completed_at),
          **Orchestration::Support.result_error_attributes(error)
        }
      end

      def run_for_input(session, request)
        current = running_run(session, request)
        return insert_follow_up(session, request) unless current

        snapshot = fetch_recovery(session, current)
        if paused_for_tools?(snapshot)
          release_paused_run(session, current)
          return insert_follow_up(session, request)
        end
        return current unless snapshot.turn&.terminal?

        apply_recovery(current, snapshot)
        insert_follow_up(session, request)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error
      end

      def paused_for_tools?(snapshot)
        Array(snapshot.tool_calls).any? && !snapshot.turn&.terminal?
      end

      def insert_follow_up(session, request)
        merged = request.merge(profile: session.profile, provider: session.provider)
        run = insert_run(merged, candidate_for(session), request[:input])
        run.update!(provider_session_id: session.provider_session_id)
        run
      end

      def insert_run(request, candidate, input)
        attribution = request.fetch(:attribution)
        RecordingStudioAI::Run.create!(
          run_identity(request, candidate, attribution).merge(
            input_character_count: input.to_s.length,
            metadata: request[:metadata].merge("submission_key" => request[:idempotency_key]).compact
          )
        )
      end

      def run_identity(request, candidate, attribution)
        {
          operation: "hosted_agent", status: "running", started_at: Time.current,
          purpose: request[:purpose], profile_key: request[:profile] || candidate_profile(candidate),
          requested_provider: request[:provider], resolved_provider: candidate.provider.to_s,
          resolved_model: candidate.model,
          **attribution_columns(attribution)
        }
      end

      def candidate_profile(_candidate)
        nil
      end

      def candidate_for(session)
        Candidate.new(provider: session.provider, model: session.model, capabilities: [:hosted_agent])
      end

      def adapter_for(provider)
        adapter = RecordingStudioAI.configuration.providers[provider.to_sym]
        return adapter if adapter && (!adapter.respond_to?(:configured?) || adapter.configured?)

        raise RecordingStudioAI::Errors::ResolutionError.new(
          category: "configuration", code: "not_configured",
          message: "No configured provider can serve hosted agent sessions."
        )
      end

      def remember_session(run, hosted)
        run.update!(
          provider_session_id: hosted.provider_session_id,
          resolved_model: hosted.model.presence || run.resolved_model
        )
      end

      def remember_turn(run, turn_id)
        return if turn_id.blank? || run.provider_turn_id.present?

        run.update!(provider_turn_id: turn_id.to_s)
      end

      def running_run(session, request)
        runs_for(session, request).find_by(status: "running")
      end

      def latest_run(session, request)
        runs_for(session, request).order(created_at: :desc).first
      end

      def runs_for(session, request)
        root_id = Orchestration::Support.identifier(request.fetch(:attribution).root_recording)
        RecordingStudioAI::Run.where(
          operation: "hosted_agent", provider_session_id: session.provider_session_id, root_recording_id: root_id
        )
      end

      def session_from(run, hosted, profile)
        Session.new(
          provider: run.resolved_provider, provider_session_id: hosted.provider_session_id,
          model: run.resolved_model, profile: profile, status: hosted.status, run_id: run.id
        )
      end

      def turn_from(run, hosted_turn = nil, session = nil, tool_calls: nil)
        calls = Array(tool_calls)
        Turn.new(
          provider: run&.resolved_provider || session.provider,
          provider_session_id: run&.provider_session_id || session.provider_session_id,
          provider_turn_id: run&.provider_turn_id || hosted_turn&.provider_turn_id,
          model: run&.resolved_model || session.model,
          status: calls.any? ? "requires_action" : (run&.status || hosted_turn&.status || "running"),
          run_id: run&.id,
          usage: usage_from(run),
          error: error_from(run) || hosted_turn&.error,
          tool_calls: calls
        )
      end

      def usage_from(run)
        return unless run&.total_tokens

        Contracts::Usage.new(
          input_tokens: run.input_tokens, output_tokens: run.output_tokens, total_tokens: run.total_tokens,
          cached_input_tokens: run.cached_input_tokens, reasoning_tokens: run.reasoning_tokens
        )
      end

      def error_from(run)
        return unless run&.error_category

        Contracts::NormalizedError.new(
          category: run.error_category, code: run.error_code || run.error_category,
          message: run.error_message || "Hosted agent turn failed.", retryable: false, provider: run.resolved_provider
        )
      end

      def replay_item?(item)
        !item.text.to_s.empty? && item.role != "user"
      end

      def item_event(item)
        Providers::StreamEvent.new(
          type: "message_completed", text: item.text,
          metadata: { item_id: item.id, provider_turn_id: item.provider_turn_id }.compact
        )
      end

      def turn_event(turn)
        type = turn.status == "completed" ? "turn_completed" : turn.status
        Providers::StreamEvent.new(type: type, usage: turn.usage, error: turn.error,
                                   metadata: { provider_turn_id: turn.provider_turn_id })
      end

      def tool_calls_event(calls)
        Providers::StreamEvent.new(
          type: "tool_calls", tool_calls: calls,
          metadata: { provider_turn_id: calls.first.provider_turn_id }
        )
      end

      def recovery_from(session, run, snapshot)
        calls = Array(snapshot.tool_calls)
        Recovery.new(
          session: replace_status(session, snapshot.session.status),
          turn: turn_from(run&.reload, snapshot.turn, session, tool_calls: calls),
          items: Array(snapshot.items).map { |item| public_item(item) },
          tool_calls: calls
        )
      end

      def public_item(item)
        Item.new(id: item.id, role: item.role, text: item.text, status: item.status,
                 provider_turn_id: item.provider_turn_id)
      end

      def replace_status(session, status)
        Session.new(
          provider: session.provider, provider_session_id: session.provider_session_id,
          model: session.model, profile: session.profile, status: status, run_id: session.run_id
        )
      end

      def attribution_for(run)
        actor = Struct.new(:id).new(run.initiator_id)
        root = Struct.new(:id).new(run.root_recording_id)
        Contracts::Attribution.new(
          root_recording: root, initiator: actor, initiator_kind: run.initiator_kind,
          execution_source: run.execution_source, request_id: run.request_id, job_id: run.job_id
        )
      end

      def metadata_with(run, extra)
        (run.metadata || {}).stringify_keys.merge(extra.stringify_keys)
      end

      def attribution_columns(attribution)
        {
          root_recording_id: Orchestration::Support.identifier(attribution.root_recording),
          context_recording_id: Orchestration::Support.identifier(attribution.context_recording),
          initiator_type: attribution.initiator.class.name,
          initiator_id: Orchestration::Support.identifier(attribution.initiator),
          initiator_kind: attribution.initiator_kind,
          executor_type: attribution.executor&.class&.name,
          executor_id: Orchestration::Support.identifier(attribution.executor),
          impersonator_type: attribution.impersonator&.class&.name,
          impersonator_id: Orchestration::Support.identifier(attribution.impersonator),
          execution_source: attribution.execution_source,
          request_id: attribution.request_id,
          job_id: attribution.job_id
        }
      end
    end
  end
end
