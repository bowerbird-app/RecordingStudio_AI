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

      def create(raw)
        request = Request.create!(**raw)
        authorize!(request)
        candidate = Resolution.call(profile: request[:profile], model: request[:model], provider: request[:provider])
        run = insert_run(request, candidate, request[:input])
        hosted = call_provider(run) do
          adapter_for(candidate.provider).create_hosted_agent_session(
            instructions: request[:instructions], model: candidate.model,
            input: request[:input], idempotency_key: request[:idempotency_key]
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
        return recovered_turn(session, run, &) if terminal_snapshot?(session, run)

        watch(session, run, &)
      end

      def cancel(raw)
        request = Request.session!(**raw)
        authorize!(request)
        session = request.fetch(:session)
        guard_session!(session, request)
        call_provider(nil) do
          adapter_for(session.provider).cancel_hosted_agent_turn(provider_session_id: session.provider_session_id)
        end
        cancel_run(running_run(session, request))
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
        finished = false
        adapter_for(session.provider).stream_hosted_agent_session(
          provider_session_id: session.provider_session_id
        ) do |event|
          finished = true if observe(run, event)
          block.call(event)
        end
        return turn_from(run.reload) if finished

        recovered_turn(session, run, &block)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?
        return recovered_turn(session, run, &block) if e.dropped?

        fail_and_raise(run, e)
      end

      def recovered_turn(session, run, &block)
        snapshot = fetch_recovery(session, run)
        apply_recovery(run, snapshot)
        Array(snapshot.items).each { |item| block.call(item_event(item)) if replay_item?(item) }
        block.call(turn_event(snapshot.turn)) if snapshot.turn&.terminal?
        turn_from(run&.reload, snapshot.turn, session)
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error if e.timeout?

        fail_and_raise(run, e)
      end

      def terminal_snapshot?(session, run)
        fetch_recovery(session, run).turn&.terminal?
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
        return unless snapshot.turn.terminal?

        text = Array(snapshot.items).map(&:text).join
        finish_run(run, snapshot.turn.status, snapshot.turn.usage, snapshot.turn.error, text)
      end

      def finish_run(run, status, usage, error, text)
        return if run.class.terminal_statuses.include?(run.status)

        assign_usage(run, usage)
        charge(run)
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

      def charge(run)
        return if run.provider_turn_id.blank? || run.total_tokens.to_i <= 0
        return if turn_charged?(run.provider_turn_id, nil)

        Usage.spend_hosted_agent_turn!(run: run, attribution: attribution_for(run))
        run.update!(metadata: metadata_with(run, "usage_charged" => true))
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

      def cancel_run(run)
        return unless run

        error = Contracts::NormalizedError.new(
          category: "cancelled", code: "cancelled", message: "Hosted agent turn was cancelled.", retryable: false
        )
        finish_run(run, "cancelled", nil, error, nil)
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
        return current if turn_still_active?(session, current)

        insert_follow_up(session, request)
      end

      def turn_still_active?(session, run)
        snapshot = fetch_recovery(session, run)
        return true unless snapshot.turn&.terminal?

        apply_recovery(run, snapshot)
        false
      rescue Providers::HostedAgentFailure => e
        raise Failure, e.error
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

      def turn_from(run, hosted_turn = nil, session = nil)
        Turn.new(
          provider: run&.resolved_provider || session.provider,
          provider_session_id: run&.provider_session_id || session.provider_session_id,
          provider_turn_id: run&.provider_turn_id || hosted_turn&.provider_turn_id,
          model: run&.resolved_model || session.model,
          status: run&.status || hosted_turn&.status || "running",
          run_id: run&.id,
          usage: usage_from(run),
          error: error_from(run) || hosted_turn&.error
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

      def recovery_from(session, run, snapshot)
        Recovery.new(
          session: replace_status(session, snapshot.session.status),
          turn: turn_from(run&.reload, snapshot.turn, session),
          items: Array(snapshot.items).map { |item| public_item(item) }
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
