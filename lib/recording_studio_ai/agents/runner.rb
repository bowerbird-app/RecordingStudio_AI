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
      DELIVERED_ITEMS_KEY = "delivered_item_ids"
      USAGE_FETCH_LIMIT = 2

      # Fiber-local. The block form sets it on the caller's fiber. An external
      # Enumerator runs in its own fiber, so abandoning stream(...).next does
      # not leave the guard set on a pooled thread. That form is not guarded.
      def self.streaming?
        Thread.current[STREAMING_KEY] == true
      end

      def create(raw)
        request = Request.create!(**raw)
        authorize!(request)
        resolved = Resolution.call(profile: request[:profile], model: request[:model], provider: request[:provider])
        candidate = resolved.candidate
        run = insert_run(request, candidate, request[:input])
        ensure_credits!(request.fetch(:attribution), run)
        hosted = call_provider(run) do
          adapter_for(candidate.provider).create_hosted_agent_session(
            instructions: request[:instructions], model: candidate.model,
            input: request[:input], idempotency_key: request[:idempotency_key],
            tools: request[:tools], reasoning_effort: resolved.reasoning_effort
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

      # Open the provider stream before reading saved items. A snapshot taken
      # first misses work that finishes before the stream attaches.
      def stream(raw, &)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = running_run(session, request) || latest_run(session, request)
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
        claimed = claim_pending_results!(session, run, results)
        continue_stream(session, run, results, claimed: claimed, &)
      end

      # A completed turn can bill after the stream returns. The job calls this.
      # Already-charged turns and blank usage return without a second charge.
      # A run with no turn id is matched to a session turn before that.
      # +false+ means the job should schedule another attempt.
      def record_deferred_turn_usage(run_id, attempt:, final:)
        run = RecordingStudioAI::Run.find_by(id: run_id)
        unless run&.status == "completed"
          log_usage_skip(run, "run_missing_or_not_completed", run_id: run_id)
          return true
        end

        prepare_turn_for_usage!(session_for_run(run), run)
        if run.provider_turn_id.blank? || run.provider_session_id.blank?
          log_usage_skip(run, "blank_session_or_turn")
          log_usage_skip(run, "gave_up") if final
          return final
        end
        if turn_held_by_another_run?(run, run.provider_turn_id)
          log_usage_skip(run, "conflict", turn_id: run.provider_turn_id)
          log_usage_skip(run, "gave_up") if final
          return final
        end
        if turn_charged?(run.provider_turn_id, nil)
          log_usage_skip(run, "already_charged", turn_id: run.provider_turn_id)
          return true
        end

        turn = read_deferred_turn(run)
        usage = turn&.usage
        if usage_reported?(usage)
          assign_usage(run, usage)
          charge(run, usage)
          log_usage_outcome(run, source: "job_attempt_#{attempt}", missing: false, turn_status: turn.status)
          return true
        end

        log_deferred_miss(run, attempt, turn&.status) if final
        log_usage_skip(run, "gave_up") if final
        final
      rescue Providers::HostedAgentFailure => e
        log_usage_fetch_failure(run, e) if run
        if run && !e.error.retryable?
          log_usage_skip(run, "fetch_not_retryable")
          return true
        end

        log_deferred_miss(run, attempt, nil) if final && run
        log_usage_skip(run, "gave_up") if final && run
        final
      end

      def recover(raw)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        run = running_run(session, request) || latest_run(session, request)
        snapshot = fetch_recovery(session, run)
        apply_recovery(session, run, snapshot)
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
            provider_session_id: session.provider_session_id,
            before_events: -> { reconcile(session, run, on_event, stop_for_tools: true) },
            &on_event
          )
        end
      end

      def continue_stream(session, run, results, claimed: nil, &block)
        ensure_credits!(attribution_for(run), run)
        consume(session, run, block, reject_provider_failure: true, submitted_results: results) do |on_event|
          adapter_for(session.provider).continue_hosted_agent_after_tool_results(
            provider_session_id: session.provider_session_id, results: results,
            before_events: -> { reconcile(session, run, on_event, stop_for_tools: false, claimed: claimed) },
            &on_event
          )
        end
      end

      def consume(session, run, handler, reject_provider_failure: false, submitted_results: nil)
        finished = false
        pending = nil
        streaming do
          yield proc { |event|
            next if skip_delivered_event?(run, event)

            finished = true if observe(session, run, event)
            pending = event.tool_calls if event.type == "tool_calls"
            handler.call(event)
            remember_delivered_item!(run, event)
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
        snapshot = fetch_recovery(session, run, item_scope: :turn)
        return turn_from(run&.reload) if ignore_stale_snapshot(run, snapshot)

        apply_recovery(session, run, snapshot)
        calls = Array(snapshot.tool_calls)
        streaming do
          replay_completed_items(run, snapshot) { |event| deliver_event(session, run, event, block) }
          if calls.any?
            deliver_event(session, run, tool_calls_event(calls), block)
          elsif snapshot.turn&.terminal?
            deliver_event(session, run, turn_event(snapshot.turn), block)
          end
        end
        return turn_from(run&.reload, snapshot.turn, session, tool_calls: calls) if calls.any?

        turn_from(run&.reload, snapshot.turn, session)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?

        fail_and_raise(run, e)
      end

      # The stream is already open. Read this turn's items, yield anything the
      # live stream will not repeat, and skip the read when that snapshot has
      # already settled. A snapshot failure other than a timeout still lets the
      # open stream play.
      def reconcile(session, run, on_event, stop_for_tools:, claimed: nil)
        snapshot = claimed || fetch_recovery(session, run, item_scope: :turn)
        return nil if ignore_stale_snapshot(run, snapshot)

        apply_recovery(session, run, snapshot)
        replay_completed_items(run, snapshot, on_event)
        deliver_settled(snapshot, on_event, stop_for_tools: stop_for_tools)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?

        nil
      end

      # :stop skips the open stream. nil keeps reading it.
      def deliver_settled(snapshot, on_event, stop_for_tools:)
        calls = Array(snapshot.tool_calls)
        terminal = snapshot.turn&.terminal?
        if calls.any? && (stop_for_tools || !terminal)
          return nil unless stop_for_tools

          on_event.call(tool_calls_event(calls))
          return :stop
        end
        return nil unless terminal

        on_event.call(turn_event(snapshot.turn))
        :stop
      end

      def fetch_recovery(session, run, item_scope: :session)
        adapter_for(session.provider).recover_hosted_agent_session(
          provider_session_id: session.provider_session_id,
          provider_turn_id: run&.provider_turn_id,
          item_scope: item_scope
        )
      end

      def observe(session, run, event) # rubocop:disable Naming/PredicateMethod -- records the event, then reports whether it ended the turn
        return false unless run

        remember_turn(run, event.metadata["provider_turn_id"])
        return false unless TERMINAL_EVENTS.include?(event.type)

        finish_run(
          run, STATUS_FOR_EVENT.fetch(event.type), event.usage, event.error, event.text, session: session
        )
        true
      end

      def apply_recovery(session, run, snapshot)
        return unless run && snapshot.turn
        return if ignore_stale_snapshot(run, snapshot)

        remember_turn(run, snapshot.turn.provider_turn_id)
        return if Array(snapshot.tool_calls).any?
        return unless snapshot.turn.terminal?

        finish_run(
          run, snapshot.turn.status, snapshot.turn.usage, snapshot.turn.error,
          assistant_output(snapshot), session: session
        )
      end

      # Completed assistant text for this turn. User text and other turns are
      # not part of the run's output size.
      def assistant_output(snapshot)
        turn_id = snapshot.turn.provider_turn_id
        Array(snapshot.items).filter_map do |item|
          next unless item.role == "assistant" && item.status == "completed"
          next unless item.provider_turn_id.blank? || item.provider_turn_id == turn_id

          item.text
        end.join
      end

      def finish_run(run, status, usage, error, text, session: nil)
        return if run.class.terminal_statuses.include?(run.status)

        settlement = nil
        if status == "completed"
          settlement = settle_inline_usage(session, run, usage)
          usage = settlement[:usage]
        end
        assign_usage(run, usage)
        charge(run, usage)
        run.update!(terminal_attributes(run, status, error, text))
        log_inline_settlement(run, settlement) if settlement
      end

      # Turn.usage is best-effort and often null on turn_completed. Read the
      # turn once on this request. A retryable error gets one more read. A
      # null result does not. Null usage is billed later by HostedTurnUsageJob.
      # This path does not sleep.
      def settle_inline_usage(session, run, usage)
        prepare_turn_for_usage!(session, run) if session

        if session.nil? || run.provider_session_id.blank? || run.provider_turn_id.blank?
          log_usage_skip(run, "blank_session_or_turn")
          enqueue_deferred_usage(run) if session && run.provider_session_id.present?
          return { usage: nil, source: "event", missing: true, silent: true }
        end
        if turn_held_by_another_run?(run, run.provider_turn_id)
          log_usage_skip(run, "conflict", turn_id: run.provider_turn_id)
          return { usage: nil, source: "event", missing: false, silent: true }
        end
        if turn_charged?(run.provider_turn_id, nil)
          log_usage_skip(run, "already_charged", turn_id: run.provider_turn_id)
          return { usage: nil, source: "event", missing: false, silent: true }
        end
        return { usage: usage, source: "event", missing: false, silent: false } if usage_reported?(usage)

        fetched, saw_null, gave_up = read_inline_usage(session, run)
        return { usage: fetched, source: "turn_retrieve", missing: false, silent: false } if usage_reported?(fetched)

        enqueue_deferred_usage(run) if saw_null && !gave_up
        { usage: nil, source: "turn_retrieve", missing: true, silent: gave_up && !saw_null }
      end

      def read_inline_usage(session, run)
        saw_null = false
        gave_up = false
        fetched = nil
        USAGE_FETCH_LIMIT.times do |attempt|
          fetched = read_turn_usage(session, run)
          saw_null = !usage_reported?(fetched)
          break
        rescue Providers::HostedAgentFailure => e
          log_usage_fetch_failure(run, e)
          retryable = e.error.retryable? && attempt < USAGE_FETCH_LIMIT - 1
          gave_up = !retryable
          if e.error.retryable?
            log_usage_skip(run, "gave_up") unless retryable
          else
            log_usage_skip(run, "fetch_not_retryable")
          end
          break unless retryable
        end
        [fetched, saw_null, gave_up]
      end

      def read_turn_usage(session, run)
        read_hosted_turn(session, run)&.usage
      end

      def read_deferred_turn(run)
        read_hosted_turn(session_for_run(run), run)
      end

      def read_hosted_turn(session, run)
        adapter_for(session.provider).retrieve_hosted_agent_turn(
          provider_session_id: session.provider_session_id,
          provider_turn_id: run.provider_turn_id
        )
      end

      def enqueue_deferred_usage(run)
        HostedTurnUsageJob.perform_later(run.id)
      end

      def usage_reported?(usage)
        return false unless usage

        token_counts = [
          usage.input_tokens, usage.output_tokens, usage.total_tokens,
          usage.cached_input_tokens, usage.reasoning_tokens
        ]
        return true if token_counts.any? { |count| count.to_i.positive? }

        usage.respond_to?(:counts) && usage.counts.values.any? { |count| count.to_i.positive? }
      end

      def log_inline_settlement(run, settlement)
        return if settlement[:silent]

        log_usage_outcome(
          run, source: settlement[:source], missing: settlement[:missing], turn_status: run.status
        )
      end

      # Ids and statuses only. No payloads and no keys.
      def log_usage_skip(run, reason, turn_id: nil, run_id: nil)
        id = run&.id || run_id
        status = run&.status || "missing"
        turn_part = turn_id.present? ? " turn_id=#{turn_id}" : ""
        warn_hosted(
          "recording_studio_ai hosted turn usage skip=#{reason} run_id=#{id} status=#{status}#{turn_part}"
        )
      end

      def log_deferred_miss(run, attempt, turn_status)
        log_usage_outcome(run, source: "job_attempt_#{attempt}", missing: true, turn_status: turn_status || run.status)
      end

      def log_usage_outcome(run, source:, missing:, turn_status:)
        completed = run.completed_at&.iso8601
        state = missing ? "unavailable" : "recorded"
        blank = missing ? " usage=nil" : ""
        message = "recording_studio_ai hosted turn usage #{state} run_id=#{run.id} " \
                  "status=#{run.status} turn_status=#{turn_status} completed_at=#{completed} " \
                  "source=#{source}#{blank}"
        warn_hosted(message)
      end

      def log_usage_fetch_failure(run, error)
        warn_hosted("recording_studio_ai hosted turn usage fetch failed run_id=#{run.id} error=#{error.class}")
      end

      # Unit tests stub warn on a nil logger. A real logger is used in the app.
      def warn_hosted(message)
        report_hosted(:warn, message)
      end

      def report_hosted(level, message)
        Rails.logger.public_send(level, message)
      rescue NoMethodError
        nil
      end

      def assign_usage(run, usage)
        return unless usage_reported?(usage)
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

        merge_metadata!(run, "usage_charged" => true)
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
        warn_hosted("recording_studio_ai cancel usage fetch failed run_id=#{run.id} error=#{error.class}")
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

        snapshot = tool_call_snapshot(session, run)
        pending = pending_calls_from(snapshot)
        run.with_lock do
          invalid_results!("hosted agent turn is not waiting on tool results") if terminal_run?(run) || pending.empty?

          match_pending_results!(pending, results)
          reject_claimed_calls!(run, results)
          remember_submitted_calls!(run, results)
        end
        snapshot
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
        snapshot = fetch_recovery(session, run, item_scope: :tool_calls)
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

      def tool_call_snapshot(session, run)
        fetch_recovery(session, run, item_scope: :tool_calls)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error
      end

      def pending_calls_from(snapshot)
        return [] if snapshot.turn&.terminal?

        Array(snapshot.tool_calls)
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

        apply_recovery(session, current, snapshot)
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
        return if turn_id.blank? || run.nil? || run.provider_turn_id.present?

        if turn_held_by_another_run?(run, turn_id)
          log_usage_skip(run, "conflict", turn_id: turn_id)
          return
        end

        run.update!(provider_turn_id: turn_id.to_s)
      end

      # A snapshot of a turn another run in this session already holds.
      # The open stream stays up. This run waits for its own turn id.
      def stale_snapshot?(run, snapshot)
        return false unless run && snapshot&.turn
        return false if run.provider_turn_id.present?

        turn_held_by_another_run?(run, snapshot.turn.provider_turn_id)
      end

      def ignore_stale_snapshot(run, snapshot)
        return unless stale_snapshot?(run, snapshot)

        log_usage_skip(run, "stale_snapshot", turn_id: snapshot.turn.provider_turn_id)
        :stale
      end

      def prepare_turn_for_usage!(session, run)
        return if run.nil?

        clear_foreign_turn!(run)
        bind_unclaimed_turn!(session, run)
      end

      def clear_foreign_turn!(run)
        return if run.provider_turn_id.blank?
        return unless turn_held_by_another_run?(run, run.provider_turn_id)

        log_usage_skip(run, "conflict", turn_id: run.provider_turn_id)
        run.update!(provider_turn_id: nil)
      end

      def bind_unclaimed_turn!(session, run)
        return if run.nil? || run.provider_turn_id.present?
        return if session.nil? || session.provider_session_id.blank?

        remember_turn(run, unclaimed_turn_id(run, list_session_turns(session, run)))
      end

      # The first session turn created at or after this run started that no
      # other run in the session holds. List order is not "latest".
      def unclaimed_turn_id(run, turns)
        eligible = Array(turns).select { |turn| turn_at_or_after_start?(run, turn) }
        eligible = eligible.sort_by(&:created_at)
        first = eligible.first
        if first && turn_held_by_another_run?(run, first.provider_turn_id)
          log_usage_skip(run, "conflict", turn_id: first.provider_turn_id)
        end
        chosen = eligible.find { |turn| !turn_held_by_another_run?(run, turn.provider_turn_id) }
        chosen&.provider_turn_id
      end

      def turn_at_or_after_start?(run, turn)
        created = turn.respond_to?(:created_at) ? turn.created_at : nil
        return false if created.nil? || run.started_at.nil?

        created >= run.started_at
      end

      def list_session_turns(session, run)
        adapter_for(session.provider).list_hosted_agent_turns(
          provider_session_id: session.provider_session_id
        )
      rescue Providers::HostedAgentFailure => e
        log_usage_fetch_failure(run, e)
        log_usage_skip(run, "fetch_not_retryable") unless e.error.retryable?
        []
      end

      def turn_held_by_another_run?(run, turn_id)
        return false if run.nil? || turn_id.blank? || run.provider_session_id.blank?

        RecordingStudioAI::Run.where(
          operation: "hosted_agent",
          provider_session_id: run.provider_session_id,
          provider_turn_id: turn_id.to_s
        ).where.not(id: run.id).exists?
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

      def replay_completed_items(run, snapshot, on_event = nil, &block)
        handler = on_event || block
        turn_id = run&.provider_turn_id.presence || snapshot.turn&.provider_turn_id
        Array(snapshot.items).each do |item|
          next unless replay_item?(item, run, turn_id)

          handler.call(item_event(item))
        end
      end

      def replay_item?(item, run, turn_id)
        return false if item.text.to_s.empty? || item.role == "user"
        return false unless item.status == "completed"
        return false if turn_id.present? && item.provider_turn_id.present? && item.provider_turn_id != turn_id
        return false if item.role == "assistant" && delivered_item?(run, item.id)

        true
      end

      def deliver_event(session, run, event, handler)
        return if skip_delivered_event?(run, event)

        observe(session, run, event)
        handler.call(event)
        remember_delivered_item!(run, event)
      end

      def skip_delivered_event?(run, event)
        return false unless run && event.type == "message_completed"

        delivered_item?(run, event.metadata["item_id"])
      end

      def delivered_item?(run, item_id)
        return false unless run

        id = item_id.to_s
        return false if id.empty?

        delivered_item_ids(run).include?(id)
      end

      def delivered_item_ids(run)
        Array(run.metadata.to_h[DELIVERED_ITEMS_KEY]).map(&:to_s)
      end

      def remember_delivered_item!(run, event)
        return unless run && event.type == "message_completed"

        id = event.metadata["item_id"].to_s
        return if id.empty?

        run.with_lock do
          ids = delivered_item_ids(run)
          next if ids.include?(id)

          run.update!(metadata: metadata_with(run, DELIVERED_ITEMS_KEY => ids + [id]))
        end
      end

      def merge_metadata!(run, extra)
        run.with_lock do
          run.update!(metadata: metadata_with(run, extra))
        end
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

      def session_for_run(run)
        Session.new(
          provider: run.resolved_provider, provider_session_id: run.provider_session_id,
          model: run.resolved_model, profile: run.profile_key, status: run.status, run_id: run.id
        )
      end

      def attribution_for(run)
        actor = Struct.new(:id).new(run.initiator_id)
        Contracts::Attribution.new(
          root_recording: run.root_recording_id, initiator: actor, initiator_kind: run.initiator_kind,
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
