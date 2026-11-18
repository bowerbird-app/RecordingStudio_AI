# frozen_string_literal: true

require "test_helper"

class HostedAgentContractTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class FakeAdapter < RecordingStudioAI::Providers::Base
    provider_key :openai

    attr_reader :creates, :submits, :streams, :cancels, :deletes, :recoveries, :tool_results, :opens,
                :usage_fetches, :trace, :provider_calls
    attr_accessor :events, :items, :item_batches, :stream_failure, :drop_after_events, :tool_result_failure,
                  :default_turn, :tool_calls, :on_tool_results, :recovery_failure, :retrieved_usages,
                  :retrieve_errors

    def initialize(configuration: nil)
      super
      @creates = []
      @submits = []
      @streams = 0
      @cancels = []
      @deletes = []
      @recoveries = []
      @recovery_turns = []
      @tool_results = []
      @tool_call_batches = []
      @tool_calls = []
      @events = []
      @items = []
      @item_batches = nil
      @opens = []
      @trace = []
      @usage_fetches = []
      @provider_calls = []
      @retrieved_usages = []
      @retrieve_errors = []
      @on_tool_results = nil
      @recovery_failure = nil
      @tool_result_failure = nil
      @drop_after_events = nil
    end

    def recovery_turns=(turns)
      @recovery_turns = turns.dup
    end

    def create_hosted_agent_session(instructions:, model:, input:, idempotency_key:, **options)
      creates << {
        instructions: instructions, model: model, input: input, idempotency_key: idempotency_key,
        tools: options[:tools], reasoning_effort: options[:reasoning_effort]
      }
      hosted_session("sess_1", model)
    end

    def submit_hosted_agent_input(provider_session_id:, input:, idempotency_key:)
      submits << {
        provider_session_id: provider_session_id, input: input, idempotency_key: idempotency_key
      }
      nil
    end

    def stream_hosted_agent_session(provider_session_id:, before_events: nil, &)
      @streams += 1
      opens << :stream
      trace << :open
      finish_open_stream(provider_session_id, before_events, &)
    end

    def cancel_hosted_agent_turn(provider_session_id:)
      cancels << provider_session_id
      nil
    end

    def delete_hosted_agent_session(provider_session_id:)
      deletes << provider_session_id
      hosted_session(provider_session_id, nil).with(status: "deleted")
    end

    def continue_hosted_agent_after_tool_results(provider_session_id:, results:, before_events: nil, &)
      opens << :continue
      trace << :open
      tool_results << { provider_session_id: provider_session_id, results: results }
      on_tool_results&.call
      raise tool_result_failure if tool_result_failure

      finish_open_stream(provider_session_id, before_events, &)
    end

    def finish_open_stream(provider_session_id, before_events, &)
      stop = before_events&.call
      raise stream_failure if stream_failure

      return provider_session_id if stop

      trace << :read
      events.each(&)
      raise drop_after_events if drop_after_events

      provider_session_id
    end

    def recover_hosted_agent_session(provider_session_id:, provider_turn_id: nil, item_scope: :session)
      raise recovery_failure if recovery_failure

      trace << :recover
      recoveries << {
        provider_session_id: provider_session_id, provider_turn_id: provider_turn_id, item_scope: item_scope
      }
      record_provider_reads(item_scope)
      turn = next_turn
      RecordingStudioAI::Providers::HostedRecovery.new(
        session: hosted_session(provider_session_id, "gpt-6-astra"),
        turn: turn,
        items: item_scope.to_sym == :tool_calls ? [] : listed_items(turn, provider_turn_id, item_scope),
        tool_calls: next_tool_calls
      )
    end

    def retrieve_hosted_agent_turn(provider_session_id:, provider_turn_id:)
      usage_fetches << { provider_session_id: provider_session_id, provider_turn_id: provider_turn_id }
      error = Array(retrieve_errors).shift
      raise error if error

      RecordingStudioAI::Providers::HostedTurn.new(
        provider_turn_id: provider_turn_id, status: "completed",
        usage: Array(retrieved_usages).shift, error: nil
      )
    end

    def tool_call_batches=(batches)
      @tool_call_batches = batches.dup
    end

    private

    def next_turn
      return @recovery_turns.shift unless @recovery_turns.empty?

      default_turn
    end

    def listed_items(turn, provider_turn_id, item_scope)
      rows = next_item_batch
      return rows unless item_scope == :turn

      turn_id = provider_turn_id.presence || turn&.provider_turn_id
      return [] if turn_id.blank?

      Array(rows).select { |item| item.provider_turn_id.blank? || item.provider_turn_id == turn_id }
    end

    def next_item_batch
      return item_batches.shift unless item_batches.nil? || item_batches.empty?

      items
    end

    def record_provider_reads(item_scope)
      provider_calls << :sessions_retrieve
      provider_calls << :turns_retrieve
      case item_scope.to_sym
      when :turn
        provider_calls << :turn_items_list
      when :tool_calls
        nil
      else
        provider_calls << :session_items_list
      end
    end

    def next_tool_calls
      return @tool_call_batches.shift unless @tool_call_batches.empty?

      tool_calls
    end

    def hosted_session(id, model)
      RecordingStudioAI::Providers::HostedSession.new(
        provider_session_id: id, status: "in_progress", model: model
      )
    end
  end

  def setup
    super
    @root = Actor.new(create_recording_id)
    @initiator = Actor.new(7)
    @configuration = isolate_allow_all_configuration!
    @configuration.openai_client = Object.new
    @fake = FakeAdapter.new(configuration: @configuration)
    RecordingStudioAI.register_provider(:openai, @fake)
    @spends = []
    @configuration.usage_precheck = ->(**) { true }
    @configuration.credit_prices = { "*" => { input: 1_000_000, output: 1_000_000 } }
    @configuration.usage_handler = ->(**kwargs) { @spends << kwargs }
    # Published Luna rates: $0.10 input and $0.50 output per 1M tokens, in microunits.
    @configuration.cost_catalogs = {
      openai: { "gpt-6-luna" => { input_tokens: 100_000, output_tokens: 500_000, currency: "USD" } }
    }
    @usage_waits = []
    @configuration.retry_sleeper = ->(seconds) { @usage_waits << seconds }
    @previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    setup_stream_events
  end

  def teardown
    ActiveJob::Base.queue_adapter = @previous_queue_adapter if @previous_queue_adapter
    super
  end

  def test_hosted_chat_uses_profile_order_and_sends_effort_only_when_one_resolves
    @configuration.profiles[:low] = [{ provider: :openai, model: "gpt-6-astra" }]
    create_session(idempotency_key: "astra-plain")
    assert_equal "gpt-6-astra", @fake.creates.first[:model]
    assert_nil @fake.creates.first[:reasoning_effort]

    @configuration.profiles[:low] = [
      { provider: :openai, model: "gpt-6-astra", reasoning_effort: "high" },
      { provider: :openai, model: "gpt-6-luna", reasoning_effort: "low" }
    ]
    create_session(idempotency_key: "astra-high")
    assert_equal "gpt-6-astra", @fake.creates.last[:model]
    assert_equal "high", @fake.creates.last[:reasoning_effort]

    create_session(model: "gpt-6-luna", profile: nil, idempotency_key: "luna-default")
    assert_equal "medium", @fake.creates.last[:reasoning_effort]
  end

  def test_create_stream_and_follow_up_record_one_run_per_turn
    session = create_session
    assert_equal :openai, session.provider
    assert_equal "sess_1", session.provider_session_id
    assert_equal "gpt-6-luna", session.model
    assert_equal "medium", @fake.creates.first[:reasoning_effort]
    assert_equal "create-1", @fake.creates.first[:idempotency_key]
    assert_equal "Be brief.", @fake.creates.first[:instructions]
    assert_nil @fake.creates.first[:tools]
    run = RecordingStudioAI::Run.find(session.run_id)
    assert_equal "hosted_agent", run.operation
    assert_equal "running", run.status
    assert_equal "sess_1", run.provider_session_id
    assert_equal @root.id, run.root_recording_id
    refute_includes run.metadata.to_s, "do-not-store-this-prompt"

    events = []
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }

    assert_equal %w[text_delta turn_completed], events.map(&:type)
    assert_equal "Hi", events.first.text_delta
    assert_equal "completed", turn.status
    assert_equal "turn_1", turn.provider_turn_id
    assert_equal 14, turn.usage.total_tokens
    assert_equal 3, turn.cost.amount
    assert_equal "USD", turn.cost.currency
    refute_includes RecordingStudioAI::Run.column_names, "cost"
    run.reload
    assert_equal "completed", run.status
    assert_equal "turn_1", run.provider_turn_id
    assert_equal 14, run.total_tokens
    assert_equal 1, @spends.length
    assert_equal 14, @spends.first[:credits]
    assert_equal "ai-hosted-agent-turn:turn_1", @spends.first[:idempotency_key]
    refute_includes @spends.first[:breakdown].to_s, "do-not-store-this-prompt"
    assert_equal({ input: 10, output: 4 }, @spends.first.dig(:breakdown, :counts))
    assert_equal "ai-hosted-agent-turn:turn_1", @spends.first[:idempotency_key]

    @fake.default_turn = completed_turn
    again = []
    RecordingStudioAI::Agents.stream(**session_args(session)) { |event| again << event }
    assert_equal 1, @spends.length
    assert_equal ["turn_completed"], again.map(&:type)
    assert_empty turn.tool_calls
  end

  def test_send_input_steers_an_active_turn_and_records_the_next_turn
    session = create_session
    @fake.recovery_turns = [active_turn]
    steered = RecordingStudioAI::Agents.send_input(
      **session_args(session), input: "steer", idempotency_key: "steer-1"
    )

    assert_equal session.run_id, steered.run_id
    assert_equal 1, RecordingStudioAI::Run.where(provider_session_id: "sess_1").count
    assert_equal "steer-1", @fake.submits.last[:idempotency_key]

    @fake.recovery_turns = [completed_turn]
    follow_up = RecordingStudioAI::Agents.send_input(
      **session_args(session), input: "next", idempotency_key: "turn-2"
    )

    assert_equal 2, RecordingStudioAI::Run.where(provider_session_id: "sess_1").count
    refute_equal session.run_id, follow_up.run_id
    assert_equal "sess_1", follow_up.provider_session_id
    assert_equal "turn-2", @fake.submits.last[:idempotency_key]
  end

  def test_stream_without_a_block_is_an_enumerator
    session = create_session
    enum = RecordingStudioAI::Agents.stream(**session_args(session))

    assert_kind_of Enumerator, enum
    assert_equal %w[text_delta turn_completed], enum.map(&:type)
  end

  def test_dropped_stream_recovers_without_resubmitting_or_double_charging
    session = create_session
    connection = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "connection", code: "network", message: "Provider connection failed.", retryable: true
    )
    @fake.stream_failure = RecordingStudioAI::Providers::HostedAgentFailure.new(connection, dropped: true)
    @fake.recovery_turns = [active_turn, completed_turn]
    @fake.items = [
      item("user", "do-not-store-this-prompt"),
      item("assistant", "saved reply")
    ]

    events = []
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }

    assert_equal 0, @fake.submits.length
    assert_equal 2, @fake.recoveries.length
    assert_equal ["saved reply"], events.filter_map(&:text)
    assert_equal "turn_completed", events.last.type
    assert_equal "completed", turn.status
    assert_equal 1, @spends.length
    refute_includes events.map(&:text).join, "do-not-store-this-prompt"
  end

  def test_timeout_leaves_the_run_running
    session = create_session
    timeout = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "timeout", code: "timeout", message: "Provider request timed out.", retryable: true
    )
    @fake.stream_failure = RecordingStudioAI::Providers::HostedAgentFailure.new(timeout, dropped: true)
    @fake.recovery_turns = [active_turn]

    error = assert_raises(RecordingStudioAI::Agents::Failure) do
      RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    end

    assert_equal "timeout", error.error.category
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
    assert_empty @spends
    assert_empty @fake.submits
  end

  def test_cancel_and_delete
    session = create_session
    cancelled = RecordingStudioAI::Agents.cancel(**session_args(session))
    assert_equal ["sess_1"], @fake.cancels
    assert_equal "cancelled", cancelled.status
    assert_equal "cancelled", RecordingStudioAI::Run.find(session.run_id).status

    deleted = RecordingStudioAI::Agents.delete_session(**session_args(cancelled))
    assert_equal ["sess_1"], @fake.deletes
    assert_equal "deleted", deleted.status
    assert RecordingStudioAI::Run.exists?(session.run_id)
  end

  def test_recover_returns_saved_items_without_a_new_submit
    session = create_session
    @fake.recovery_turns = [completed_turn]
    @fake.items = [item("assistant", "saved reply")]

    recovery = RecordingStudioAI::Agents.recover(**session_args(session))

    assert_equal "completed", recovery.turn.status
    assert_equal "saved reply", recovery.items.first.text
    assert_empty @fake.submits
    assert_equal "completed", RecordingStudioAI::Run.find(session.run_id).status
  end

  def test_missing_model_is_a_configuration_error
    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      create_session(model: "missing-model", profile: nil)
    end

    assert_equal "configuration", error.category
    assert_equal "missing_model", error.code
    assert_match(/missing-model/, error.message)
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_generation_model_is_not_hosted_agent_capable
    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      create_session(model: "gpt-5", profile: nil)
    end

    assert_equal "unsupported_capability", error.category
    assert_equal "unsupported_capability", error.code
  end

  def test_generation_resolution_skips_the_hosted_agent_model
    candidate = RecordingStudioAI::Resolver.new.resolve(profile: :low, required_capabilities: [:generation])

    assert_equal "gpt-5-mini", candidate.model
  end

  def test_unimplemented_providers_raise_unsupported_capability
    gemini = RecordingStudioAI::Providers::Gemini.new(configuration: @configuration)
    error = assert_raises(RecordingStudioAI::Providers::UnsupportedCapabilityError) do
      gemini.create_hosted_agent_session(
        instructions: nil, model: "gemini-2.5-flash", input: "Hi", idempotency_key: "k"
      )
    end
    assert_equal :hosted_agent, error.capability
    assert_equal :gemini, error.provider

    bare = Class.new(RecordingStudioAI::Providers::Base) do
      def self.name
        "RecordingStudioAI::Providers::BareHosted"
      end
    end.new
    bare_error = assert_raises(RecordingStudioAI::Providers::UnsupportedCapabilityError) do
      bare.stream_hosted_agent_session(provider_session_id: "sess") { |_event| }
    end
    assert_equal :hosted_agent, bare_error.capability
    assert_equal :barehosted, bare_error.provider
  end

  def test_the_owning_root_can_use_every_session_entry_point
    session = create_session
    @fake.default_turn = active_turn

    RecordingStudioAI::Agents.send_input(**session_args(session), input: "more", idempotency_key: "own-1")
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    RecordingStudioAI::Agents.cancel(**session_args(session))
    RecordingStudioAI::Agents.recover(**session_args(session))
    RecordingStudioAI::Agents.delete_session(**session_args(session))

    assert_equal 1, @fake.submits.length
    assert_equal 1, @fake.streams
    assert_equal ["sess_1"], @fake.cancels
    refute_empty @fake.recoveries
    assert_equal ["sess_1"], @fake.deletes
  end

  def test_another_root_cannot_use_a_session
    session = create_session

    assert_entry_points_denied(session, Actor.new(create_recording_id))
  end

  def test_a_session_with_no_run_on_the_caller_is_denied
    session = RecordingStudioAI::Agents::Session.new(
      provider: :openai, provider_session_id: "sess_unknown", model: "gpt-6-astra"
    )

    assert_entry_points_denied(session, @root)
  end

  def test_a_session_shared_with_another_root_is_denied
    session = create_session
    copy_run(session, Actor.new(create_recording_id))

    assert_entry_points_denied(session, @root)
  end

  def test_authorization_denial_does_not_create_a_run
    @configuration.authorization_handler = ->(**) { false }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { create_session }
    assert_equal "authorization", error.code
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty @fake.creates
  end

  def test_tool_and_result_contracts_reject_bad_input
    session = create_session
    [
      { tools: "list" },
      { tools: [{ type: "function", name: "Bad Name", description: "x", parameters: { type: "object" } }] },
      { tools: [{ type: "function", name: "list_recordings", description: " ", parameters: { type: "string" } }] },
      { tools: [{ type: "function", name: "list_recordings", description: "List.",
                  parameters: { type: "object" }, extra: 1 }] },
      { tools: [function_tool, function_tool] }
    ].each do |extra|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { create_session(**extra) }
      assert_equal "invalid_request", error.code
    end

    [
      [],
      [{ call_id: "call_1", turn_id: "turn_1" }],
      [{ call_id: "call_1", turn_id: "turn_1", output: "ok", error: "no" }],
      [{ call_id: "call_1", turn_id: "turn_1", output: { ok: true } }],
      [
        { call_id: "call_1", turn_id: "turn_1", output: "ok" },
        { call_id: "call_1", turn_id: "turn_1", error: "again" }
      ],
      [{ call_id: "call_1", turn_id: "turn_1", output: "x" * (max_result_bytes + 1) }],
      [{ call_id: "call_1", turn_id: "turn_1", error: "x" * (max_result_bytes + 1) }]
    ].each do |results|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: results) { |_event| }
      end
      assert_equal "invalid_request", error.code
    end
    assert_empty @fake.tool_results
  end

  def test_tools_pass_through_and_other_tool_types_are_rejected
    tools = [
      {
        type: "function", name: "list_recordings", description: "List them.",
        parameters: { type: "object", properties: { limit: { type: "integer" } } },
        defer_loading: false
      }
    ]
    create_session(tools: tools)

    assert_equal [function_tool], @fake.creates.first[:tools]

    create_session
    omitted = @fake.creates.last
    create_session(tools: [])

    assert_nil omitted[:tools]
    assert_equal omitted, @fake.creates.last
    runs = RecordingStudioAI::Run.count
    creates = @fake.creates.length

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      create_session(tools: [{ type: "mcp", server_label: "rs" }])
    end
    assert_equal runs, RecordingStudioAI::Run.count
    assert_equal creates, @fake.creates.length
  end

  def test_submit_tool_results_round_trip
    session = create_session
    call = tool_call("call_1")
    @fake.events = [tool_calls_event(call)]
    seen = []
    paused = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| seen << event }

    assert_equal ["tool_calls"], seen.map(&:type)
    assert_equal "call_1", paused.tool_calls.first.call_id
    assert_equal({ "limit" => 2 }, paused.tool_calls.first.arguments)
    assert_equal "requires_action", paused.status
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
    assert_empty @fake.tool_results

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Agents.stream(**session_args(session)) do |event|
        next unless event.type == "tool_calls"

        RecordingStudioAI::Agents.submit_tool_results(
          **session_args(session), results: [tool_result(call)]
        ) { |_ignored| }
      end
    end
    assert_equal "invalid_request", error.code

    second = tool_call("call_2")
    @fake.tool_calls = [call, second]
    @fake.default_turn = nil
    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "text_delta", text_delta: "Done", metadata: { provider_turn_id: "turn_9" }
      ),
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, metadata: { provider_turn_id: "turn_9" }
      )
    ]
    continued = []
    turn = RecordingStudioAI::Agents.submit_tool_results(
      **session_args(session), results: [tool_result(call), tool_result(second, error: "missing")]
    ) { |event| continued << event }

    assert_equal %w[text_delta turn_completed], continued.map(&:type)
    assert_equal "completed", turn.status
    assert_empty turn.tool_calls
    posted = @fake.tool_results.last[:results]
    posted_ids = posted.map { |result| result[:call_id] }
    assert_equal %w[call_1 call_2], posted_ids
    assert_equal "ok", posted[0][:output]
    assert_equal "missing", posted[1][:error]
    assert_equal "completed", RecordingStudioAI::Run.find(session.run_id).status
  end

  def test_submit_tool_results_rejects_results_that_are_not_pending
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_rejected_results(session, run, [{ call_id: "call_stale", turn_id: "turn_9", output: "ok" }])
    assert_rejected_results(session, run, [{ call_id: "call_1", turn_id: "turn_other", output: "ok" }])
    assert_empty @fake.tool_results
    assert_empty @spends

    @fake.tool_calls = []
    assert_rejected_results(session, run, [tool_result(call)])
    assert_equal "running", run.reload.status

    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, metadata: { provider_turn_id: "turn_9" }
      )
    ]
    @fake.tool_calls = [call]
    RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
    assert_equal "completed", run.reload.status
    assert_equal 1, @spends.length
    assert_equal 1, @fake.tool_results.length

    assert_rejected_results(session, run, [tool_result(call)])
    assert_equal "completed", run.reload.status
    assert_equal 1, @spends.length
    assert_equal 1, @fake.tool_results.length
  end

  def test_a_new_message_cancels_a_paused_run_and_bills_its_usage_once
    session = create_session
    @fake.tool_calls = [tool_call("call_1")]
    @fake.default_turn = paused_turn
    paused = RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    assert_equal "requires_action", paused.status
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
    assert_empty @spends

    follow = RecordingStudioAI::Agents.send_input(
      **session_args(session), input: "next question", idempotency_key: "next-1"
    )
    paused_run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "cancelled", paused_run.status
    assert_equal 14, paused_run.total_tokens
    assert_equal 1, @spends.length
    assert_equal 14, @spends.first[:credits]
    assert_equal "ai-hosted-agent-turn:turn_1", @spends.first[:idempotency_key]
    assert_equal ["sess_1"], @fake.cancels
    assert_equal "next-1", @fake.submits.last[:idempotency_key]
    refute_equal paused_run.id, follow.run_id
    assert_equal "running", RecordingStudioAI::Run.find(follow.run_id).status
    assert_equal "sess_1", follow.provider_session_id
  end

  def test_cancelling_a_terminal_run_does_not_bill_again
    session = create_session
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "completed", run.status
    assert_equal 1, @spends.length

    cancelled = RecordingStudioAI::Agents.cancel(**session_args(session))

    assert_equal "cancelled", cancelled.status
    assert_equal "completed", run.reload.status
    assert_equal 1, @spends.length
    assert_equal ["sess_1"], @fake.cancels
  end

  def test_cancel_bills_a_paused_run_once
    session = create_session
    @fake.tool_calls = [tool_call("call_1")]
    @fake.default_turn = paused_turn
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    RecordingStudioAI::Agents.cancel(**session_args(session))
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "cancelled", run.status
    assert_equal 14, run.total_tokens
    assert_equal 1, @spends.length

    RecordingStudioAI::Agents.cancel(**session_args(session))

    assert_equal "cancelled", run.reload.status
    assert_equal 1, @spends.length
    assert_equal 2, @fake.cancels.length
  end

  def test_unparsed_tool_arguments_can_be_recovered_and_answered
    session = create_session
    call = RecordingStudioAI::Agents::ToolCall.new(
      call_id: "call_bad", name: "list_recordings", arguments: nil, provider_turn_id: "turn_9",
      arguments_error: "function call arguments must be a JSON object", raw_arguments: "[]"
    )
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    recovery = RecordingStudioAI::Agents.recover(**session_args(session))

    assert_nil recovery.tool_calls.first.arguments
    assert_equal "[]", recovery.tool_calls.first.raw_arguments
    assert_equal "function call arguments must be a JSON object", recovery.tool_calls.first.arguments_error
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status

    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, metadata: { provider_turn_id: "turn_9" }
      )
    ]
    turn = RecordingStudioAI::Agents.submit_tool_results(
      **session_args(session),
      results: [{ call_id: "call_bad", turn_id: "turn_9", error: "could not read arguments" }]
    ) { |_event| }

    assert_equal "completed", turn.status
    assert_equal "could not read arguments", @fake.tool_results.last[:results].first[:error]
  end

  def test_an_abandoned_stream_enumerator_does_not_block_submit_tool_results
    session = create_session
    enum = RecordingStudioAI::Agents.stream(**session_args(session))
    assert_equal "text_delta", enum.next.type

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result]) { |_event| }
    end

    assert_equal "invalid_request", error.code
    assert_match(/not waiting on tool results/, error.message)
    refute_match(/after stream returns/, error.message)
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
    assert_empty @fake.tool_results
    assert_empty @spends
  end

  # Same connection as the in-flight submit. Persistence tests use a
  # per-connection SQLite :memory: database, so a second thread from the pool
  # cannot see this run or take its row lock. This checks the recorded-id
  # rejection, which runs after the ids are saved and before the post returns.
  def test_a_second_submit_on_the_same_connection_is_rejected_after_call_ids_are_recorded
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, metadata: { provider_turn_id: "turn_9" }
      )
    ]
    raced = nil
    @fake.on_tool_results = lambda do
      Fiber.new do
        raced = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
          RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) do
            |_event|
          end
        end
        assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
      end.resume
    end

    turn = RecordingStudioAI::Agents.submit_tool_results(
      **session_args(session), results: [tool_result(call)]
    ) { |_event| }
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "invalid_request", raced.code
    assert_match(/already submitted: call_1/, raced.message)
    assert_equal "completed", turn.status
    assert_equal "completed", run.status
    assert_equal 1, @spends.length
    assert_equal 14, @spends.first[:credits]
    assert_equal 1, @fake.tool_results.length
  end

  def test_a_provider_rejection_of_tool_results_does_not_fail_the_run
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    @fake.tool_result_failure = hosted_failure(
      "provider_error",
      code: "http_400",
      message: "Provider request failed.",
      retryable: false,
      tool_results_rejected: true
    )

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "invalid_request", error.code
    assert_equal "hosted agent rejected the tool results", error.message
    assert_equal "running", run.status
    assert_empty @spends
    assert_equal [], run.metadata["submitted_tool_call_ids"]
  end

  def test_a_rejected_tool_result_can_be_retried_and_bills_once
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    @fake.tool_result_failure = hosted_failure(
      "provider_error",
      code: "http_400",
      message: "Provider request failed.",
      retryable: false,
      tool_results_rejected: true
    )

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "invalid_request", error.code
    assert_equal "running", run.status
    assert_empty @spends
    assert_equal [], run.metadata["submitted_tool_call_ids"]

    @fake.tool_result_failure = nil
    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, metadata: { provider_turn_id: "turn_9" }
      )
    ]
    turn = RecordingStudioAI::Agents.submit_tool_results(
      **session_args(session), results: [tool_result(call)]
    ) { |_event| }

    assert_equal "completed", turn.status
    assert_equal "completed", run.reload.status
    assert_equal 1, @spends.length
    assert_equal 14, @spends.first[:credits]
    assert_equal 2, @fake.tool_results.length
  end

  def test_submit_failures_other_than_a_4xx_rejection_keep_the_provider_error
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    [
      ["timeout", "timeout", "Provider request timed out.", true],
      ["authentication", "invalid_credentials", "Provider authentication failed.", false],
      ["rate_limit", "rate_limit_exceeded", "Provider rate limit exceeded.", true],
      ["provider_unavailable", "503", "Provider is unavailable.", true]
    ].each do |category, code, message, retryable|
      @fake.tool_result_failure = hosted_failure(category, code: code, message: message, retryable: retryable)
      spends = @spends.length

      error = assert_raises(RecordingStudioAI::Agents::Failure) do
        RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
      end
      run = RecordingStudioAI::Run.find(session.run_id)

      assert_equal category, error.error.category, category
      assert_equal retryable, error.error.retryable?, category
      assert_equal "running", run.status, category
      assert_equal spends, @spends.length, category
      assert_equal [], run.metadata["submitted_tool_call_ids"], category
    end
  end

  def test_a_continuation_failure_keeps_an_accepted_call_recorded
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    @fake.on_tool_results = -> { @fake.tool_calls = [] }
    @fake.stream_failure = hosted_failure(
      "provider_unavailable", code: "503", message: "Provider is unavailable.", retryable: true
    )

    error = assert_raises(RecordingStudioAI::Agents::Failure) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "provider_unavailable", error.error.category
    assert_predicate error.error, :retryable?
    assert_equal "running", run.status
    assert_equal ["call_1"], run.metadata["submitted_tool_call_ids"]
  end

  def test_a_continuation_failure_releases_call_ids_the_provider_still_lists
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    @fake.stream_failure = hosted_failure(
      "provider_error", code: "http_400", message: "Provider request failed.", retryable: false
    )

    error = assert_raises(RecordingStudioAI::Agents::Failure) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "provider_error", error.error.category
    refute_predicate error.error, :retryable?
    assert_equal "running", run.status
    assert_equal [], run.metadata["submitted_tool_call_ids"]
  end

  def test_a_rejected_submit_keeps_claimed_ids_when_the_pending_reread_fails
    session = create_session
    call = tool_call("call_1")
    @fake.tool_calls = [call]
    @fake.default_turn = active_turn
    @fake.tool_result_failure = hosted_failure(
      "provider_error",
      code: "http_400",
      message: "Provider request failed.",
      retryable: false,
      tool_results_rejected: true
    )
    @fake.on_tool_results = lambda do
      @fake.recovery_failure = hosted_failure(
        "provider_unavailable", code: "503", message: "Provider is unavailable.", retryable: true
      )
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: [tool_result(call)]) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "invalid_request", error.code
    assert_equal "running", run.status
    assert_equal ["call_1"], run.metadata["submitted_tool_call_ids"]
  end

  def test_cancel_still_cancels_when_the_usage_fetch_fails
    session = create_session
    run = RecordingStudioAI::Run.find(session.run_id)
    @fake.recovery_failure = RecordingStudioAI::Providers::HostedAgentFailure.new(
      RecordingStudioAI::Contracts::NormalizedError.new(
        category: "provider_unavailable", code: "503", message: "Provider is unavailable.", retryable: true
      )
    )
    messages = []
    cancelled = nil
    Rails.logger.stub(:warn, ->(message = nil) { messages << message.to_s }) do
      cancelled = RecordingStudioAI::Agents.cancel(**session_args(session))
    end

    assert_equal ["sess_1"], @fake.cancels
    assert_equal "cancelled", cancelled.status
    assert_equal "cancelled", run.reload.status
    assert_empty @spends
    assert_match(/run_id=#{run.id}/, messages.join(" "))
    assert_match(/HostedAgentFailure/, messages.join(" "))
  end

  def test_recover_after_an_early_cancel_records_the_provider_turn_id
    session = create_session
    @fake.recovery_failure = hosted_failure(
      "provider_unavailable", code: "503", message: "Provider is unavailable.", retryable: true
    )
    logger = ActiveSupport::Logger.new(File::NULL)
    Rails.stub(:logger, logger) do
      RecordingStudioAI::Agents.cancel(**session_args(session))
    end
    run = RecordingStudioAI::Run.find(session.run_id)
    assert_equal "cancelled", run.status
    assert_nil run.provider_turn_id

    @fake.recovery_failure = nil
    @fake.recovery_turns = [completed_turn]
    recovery = RecordingStudioAI::Agents.recover(**session_args(session))

    assert_equal "turn_1", recovery.turn.provider_turn_id
    assert_equal "cancelled", run.reload.status
    assert_equal "turn_1", run.provider_turn_id
  end

  def test_cancel_usage_fetch_raises_unexpected_errors
    session = create_session
    run = RecordingStudioAI::Run.find(session.run_id)
    @fake.recovery_failure = RuntimeError.new("metadata store down")
    messages = []

    Rails.logger.stub(:warn, ->(message = nil) { messages << message.to_s }) do
      assert_raises(RuntimeError) { RecordingStudioAI::Agents.cancel(**session_args(session)) }
    end

    assert_equal ["sess_1"], @fake.cancels
    assert_equal "running", run.reload.status
    assert_empty @spends
    assert_empty messages
  end

  def test_recovery_reports_pending_tool_calls
    session = create_session
    call = tool_call("call_9")
    @fake.default_turn = active_turn
    @fake.tool_calls = [call]

    events = []
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }

    assert_equal 1, @fake.streams
    assert_equal %i[open recover], @fake.trace
    assert_equal ["tool_calls"], events.map(&:type)
    assert_equal "call_9", turn.tool_calls.first.call_id
    assert_equal "requires_action", turn.status
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status

    recovery = RecordingStudioAI::Agents.recover(**session_args(session))
    assert_equal ["call_9"], recovery.tool_calls.map(&:call_id)
    assert_equal "requires_action", recovery.turn.status
  end

  def test_dropped_stream_reports_tool_calls_discovered_after_the_drop
    session = create_session
    connection = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "connection", code: "network", message: "Provider connection failed.", retryable: true
    )
    @fake.stream_failure = RecordingStudioAI::Providers::HostedAgentFailure.new(connection, dropped: true)
    @fake.recovery_turns = [active_turn, active_turn]
    @fake.tool_call_batches = [[], [tool_call("call_drop")]]

    events = []
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }

    assert_equal 1, @fake.streams
    assert_equal ["tool_calls"], events.map(&:type)
    assert_equal "call_drop", turn.tool_calls.first.call_id
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
  end

  def test_normal_stream_delivers_each_message_once
    session = create_session
    @fake.events = [
      delta_event("Hi", "item_live"),
      message_event("Hi", "item_live"),
      message_event("Plain", nil),
      turn_event_for("turn_1")
    ]
    events = []
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }

    assert_equal %w[text_delta message_completed message_completed turn_completed], events.map(&:type)
    assert_equal %w[Hi Plain], events.filter_map(&:text)
    assert_equal ["item_live"], delivered_ids(session)
    assert_equal "completed", turn.status
    assert_equal 1, @spends.length
    assert_equal %i[open recover read], @fake.trace
  end

  def test_dropped_stream_delivers_the_final_partial_message_once
    session = create_session
    done = item("assistant", "Done", id: "item_done")
    partial = item("assistant", "Hel", id: "item_partial", status: "in_progress")
    finished = item("assistant", "Hello", id: "item_partial")
    earlier = item("assistant", "Earlier", id: "item_old", turn_id: "turn_0")
    prompt = item("user", "prompt-text", id: "item_user")
    @fake.recovery_turns = [active_turn, completed_turn]
    @fake.item_batches = [[done, partial], [prompt, done, finished, earlier]]
    @fake.events = [message_event("Done", "item_done"), delta_event("Hel", "item_partial")]
    @fake.drop_after_events = dropped_failure
    events = []
    RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal %w[Done Hello], events.filter_map(&:text)
    assert_equal %w[item_done item_partial], delivered_ids(session)
    assert_equal "DoneHello".length, run.output_character_count
    assert_equal "completed", run.status
    assert_equal 1, @spends.length
  end

  def test_tool_call_rounds_deliver_each_message_once
    session = create_session
    call = tool_call("call_round")
    @fake.item_batches = [[], [], [item("assistant", "Alpha", id: "item_a", turn_id: "turn_9")]]
    @fake.events = [message_event("Alpha", "item_a", turn_id: "turn_9"), tool_calls_event(call)]
    first = []
    paused = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| first << event }

    assert_equal ["Alpha"], first.filter_map(&:text)
    assert_equal "requires_action", paused.status
    assert_equal %i[open recover read], @fake.trace

    @fake.tool_calls = [call]
    @fake.events = [message_event("Beta", "item_b", turn_id: "turn_9"), turn_event_for("turn_9")]
    second = []
    turn = RecordingStudioAI::Agents.submit_tool_results(
      **session_args(session), results: [tool_result(call)]
    ) { |event| second << event }

    assert_equal ["Beta"], second.filter_map(&:text)
    assert_equal "completed", turn.status
    assert_equal %w[item_a item_b], delivered_ids(session)
    assert_equal %i[stream continue], @fake.opens
    assert_equal 1, @spends.length
  end

  def test_one_turn_delivers_several_assistant_messages_once
    session = create_session
    @fake.events = [
      message_event("One", "item_1"),
      message_event("Two", "item_2"),
      message_event("Three", "item_3"),
      turn_event_for("turn_1")
    ]
    events = []
    RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }

    assert_equal %w[One Two Three], events.filter_map(&:text)
    assert_equal %w[item_1 item_2 item_3], delivered_ids(session)
    assert_equal 1, @spends.length
  end

  def test_stream_after_the_turn_finished_delivers_each_message_once
    session = create_session
    @fake.default_turn = completed_turn
    @fake.items = [
      item("user", "prompt-text", id: "item_user"),
      item("assistant", "Kept", id: "item_kept"),
      item("assistant", "Also", id: "item_also"),
      item("assistant", "Working", id: "item_open", status: "in_progress")
    ]
    @fake.events = [message_event("Kept", "item_kept"), message_event("Extra", "item_extra")]
    events = []
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal %i[open recover], @fake.trace
    assert_equal %w[Kept Also], events.filter_map(&:text)
    assert_equal "turn_completed", events.last.type
    assert_equal "completed", turn.status
    assert_equal %w[item_kept item_also], delivered_ids(session)
    assert_equal "KeptAlso".length, run.output_character_count
    assert_equal 1, @spends.length
  end

  def test_a_new_runner_honors_delivered_item_ids
    session = create_session
    @fake.events = [message_event("Kept", "item_kept"), turn_event_for("turn_1")]
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    assert_equal ["item_kept"], RecordingStudioAI::Run.find(session.run_id).metadata["delivered_item_ids"]

    @fake.trace.clear
    @fake.default_turn = completed_turn
    @fake.items = [
      item("assistant", "Kept", id: "item_kept"),
      item("assistant", "Next", id: "item_next")
    ]
    @fake.events = [message_event("Kept", "item_kept"), message_event("Next", "item_next")]
    events = []
    RecordingStudioAI::Agents::Runner.new.stream(session_args(session)) { |event| events << event }

    assert_equal %i[open recover], @fake.trace
    assert_equal ["Next"], events.filter_map(&:text)
    assert_equal %w[item_kept item_next], delivered_ids(session)
    assert_equal 1, @spends.length
  end

  def test_replay_skips_messages_from_earlier_turns
    session = create_session
    RecordingStudioAI::Run.find(session.run_id).update!(provider_turn_id: "turn_1")
    @fake.default_turn = completed_turn
    @fake.items = [
      item("user", "prompt-text", id: "item_user"),
      item("assistant", "Old", id: "item_old", turn_id: "turn_0"),
      item("assistant", "New", id: "item_new"),
      item("assistant", "Partial", id: "item_partial", status: "in_progress")
    ]
    events = []
    RecordingStudioAI::Agents.stream(**session_args(session)) { |event| events << event }
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal ["New"], events.filter_map(&:text)
    assert_equal ["item_new"], run.metadata["delivered_item_ids"]
    assert_equal "New".length, run.output_character_count
  end

  def test_a_failed_handler_does_not_mark_the_item_delivered
    session = create_session
    @fake.events = [message_event("Hi", "item_live"), turn_event_for("turn_1")]

    assert_raises(RuntimeError) do
      RecordingStudioAI::Agents.stream(**session_args(session)) do |event|
        raise "stop" if event.type == "message_completed"
      end
    end

    assert_nil delivered_ids(session)
    assert_equal "running", RecordingStudioAI::Run.find(session.run_id).status
  end

  def test_null_turn_usage_is_read_once_and_charged_by_the_job
    session = create_session
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    @fake.retrieved_usages = [nil, nil, usage]
    messages = []
    turn = nil
    with_usage_logs(messages) do
      turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal 1, @fake.usage_fetches.length
    assert_equal "sess_1", @fake.usage_fetches.first[:provider_session_id]
    assert_equal "turn_1", @fake.usage_fetches.first[:provider_turn_id]
    assert_nil turn.usage
    assert_empty @spends
    assert_equal "completed", run.status
    refute run.metadata.to_h["usage_charged"]
    assert_equal([[run.id]], enqueued_usage_jobs.map { |job| job[:args] })
    assert_empty @usage_waits
    assert_match(/source=turn_retrieve/, messages.join("\n"))
    assert_match(/run_id=#{run.id}/, messages.join("\n"))
    assert_match(/status=completed/, messages.join("\n"))
    assert_match(/turn_status=completed/, messages.join("\n"))
    assert_match(/completed_at=\d{4}-\d{2}-\d{2}T/, messages.join("\n"))
    assert_match(/usage=nil/, messages.join("\n"))

    with_usage_logs(messages) do
      RecordingStudioAI::HostedTurnUsageJob.perform_now(run.id)
    end
    run.reload

    assert_equal [5], @usage_waits
    assert_equal 10, run.input_tokens
    assert_equal 4, run.output_tokens
    assert_equal 14, run.total_tokens
    assert_equal 1, @spends.length
    assert_equal 14, @spends.first[:credits]
    assert_equal "ai-hosted-agent-turn:turn_1", @spends.first[:idempotency_key]
    assert run.metadata["usage_charged"]
    assert_match(/source=job_attempt_2/, messages.join("\n"))
    assert_match(/turn_status=completed/, messages.join("\n"))
    refute_match(/idempotency|api_key|sk-/i, messages.join("\n"))

    @usage_waits.clear
    RecordingStudioAI::HostedTurnUsageJob.perform_now(run.id)

    assert_equal 1, @spends.length
    assert_empty @usage_waits
    assert run.metadata["usage_charged"]
    run.total_tokens = 15
    refute run.save
    assert_includes run.errors.full_messages.join(" "), "terminal"
    assert_equal 14, run.reload.total_tokens
  end

  def test_null_usage_retries_leave_the_run_uncharged
    session = create_session
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    @fake.retrieved_usages = []
    messages = []
    with_usage_logs(messages) do
      RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
      run = RecordingStudioAI::Run.find(session.run_id)
      RecordingStudioAI::HostedTurnUsageJob.perform_now(run.id)
    end
    run = RecordingStudioAI::Run.find(session.run_id)
    logged = messages.join("\n")

    assert_equal 6, @fake.usage_fetches.length
    assert_equal [5, 30, 120, 600], @usage_waits
    assert_nil run.total_tokens
    assert_empty @spends
    assert_equal "completed", run.status
    refute run.metadata.to_h["usage_charged"]
    assert_match(/run_id=#{run.id}/, logged)
    assert_match(/status=completed/, logged)
    assert_match(/turn_status=completed/, logged)
    assert_match(/completed_at=\d{4}-\d{2}-\d{2}T/, logged)
    assert_match(/source=turn_retrieve/, logged)
    assert_match(/source=job_attempt_5/, logged)
    assert_match(/usage=nil/, logged)
    refute_match(/idempotency|api_key|sk-/i, logged)
  end

  def test_empty_usage_does_not_mark_the_run_charged
    session = create_session
    empty = RecordingStudioAI::Contracts::Usage.new
    @fake.events = [turn_event_for("turn_1", usage: empty)]
    @fake.retrieved_usages = [empty]
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    run = RecordingStudioAI::Run.find(session.run_id)
    RecordingStudioAI::HostedTurnUsageJob.perform_now(run.id)
    run.reload

    assert_nil run.total_tokens
    assert_empty @spends
    refute run.metadata.to_h["usage_charged"]
  end

  def test_inline_usage_read_does_not_sleep
    session = create_session
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    @fake.retrieved_usages = [nil, usage]
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1
    assert_empty @usage_waits
    assert_equal 1, @fake.usage_fetches.length
    assert_equal 1, enqueued_usage_jobs.length
  end

  def test_a_tool_pause_reads_the_turn_once_and_skips_the_session_item_list
    session = create_session
    call = tool_call("call_1")
    @fake.events = [tool_calls_event(call)]
    paused = RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    assert_equal "requires_action", paused.status
    @fake.provider_calls.clear
    @fake.recoveries.clear
    @fake.tool_calls = [call]
    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, metadata: { provider_turn_id: "turn_9" }
      )
    ]
    turn = RecordingStudioAI::Agents.submit_tool_results(
      **session_args(session), results: [tool_result(call)]
    ) { |_event| }

    assert_equal "completed", turn.status
    assert_equal %i[sessions_retrieve turns_retrieve], @fake.provider_calls
    assert_equal([:tool_calls], @fake.recoveries.map { |recovery| recovery[:item_scope] })
    refute_includes @fake.provider_calls, :session_items_list
    refute_includes @fake.provider_calls, :turn_items_list
  end

  def test_turn_usage_read_retries_a_retryable_failure_once
    session = create_session
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    @fake.retrieve_errors = [
      hosted_failure("connection", code: "network", message: "Provider connection failed.", retryable: true)
    ]
    @fake.retrieved_usages = [usage]
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    assert_equal 2, @fake.usage_fetches.length
    assert_equal 14, turn.usage.total_tokens
    assert_equal 1, @spends.length
    assert_empty enqueued_usage_jobs
    assert_empty @usage_waits
  end

  def test_turn_usage_read_does_not_retry_a_non_retryable_failure
    session = create_session
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    @fake.retrieve_errors = [
      hosted_failure("provider_error", code: "provider_error", message: "Provider request failed.", retryable: false)
    ]
    @fake.retrieved_usages = [usage]
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    assert_equal 1, @fake.usage_fetches.length
    assert_nil turn.usage
    assert_empty @spends
    assert_equal "completed", RecordingStudioAI::Run.find(session.run_id).status
    assert_empty enqueued_usage_jobs
  end

  def test_turn_usage_timeout_leaves_the_completed_run_unbilled
    session = create_session
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    timeout = hosted_failure("timeout", code: "timeout", message: "Provider request timed out.", retryable: true)
    @fake.retrieve_errors = [timeout, timeout]
    turn = RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    assert_equal "completed", turn.status
    assert_nil turn.usage
    assert_empty @spends
    assert_equal 2, @fake.usage_fetches.length
    assert_empty enqueued_usage_jobs
    assert_empty @usage_waits
  end

  def test_null_usage_skips_a_turn_that_was_already_charged
    session = create_session
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }
    assert_equal 1, @spends.length

    @fake.default_turn = completed_turn
    RecordingStudioAI::Agents.send_input(**session_args(session), input: "next", idempotency_key: "turn-2")
    @fake.default_turn = nil
    @fake.events = [turn_event_for("turn_1", usage: nil)]
    @fake.retrieved_usages = [usage]
    @fake.usage_fetches.clear
    RecordingStudioAI::Agents.stream(**session_args(session)) { |_event| }

    assert_empty @fake.usage_fetches
    assert_equal 1, @spends.length
  end

  private

  def create_session(model: nil, profile: :low, tools: nil, idempotency_key: "create-1")
    args = {
      instructions: "Be brief.",
      input: "do-not-store-this-prompt",
      idempotency_key: idempotency_key,
      purpose: "agent_chat",
      root_recording: @root,
      initiator: @initiator
    }
    args[:profile] = profile unless profile.nil?
    args[:model] = model if model
    args[:tools] = tools if tools
    RecordingStudioAI::Agents.create_session(**args)
  end

  def function_tool
    {
      type: "function",
      name: "list_recordings",
      description: "List them.",
      parameters: { "type" => "object", "properties" => { "limit" => { "type" => "integer" } } },
      defer_loading: false
    }
  end

  def tool_call(call_id)
    RecordingStudioAI::Agents::ToolCall.new(
      call_id: call_id, name: "list_recordings", arguments: { "limit" => 2 }, provider_turn_id: "turn_9"
    )
  end

  def tool_calls_event(call)
    RecordingStudioAI::Providers::StreamEvent.new(
      type: "tool_calls", tool_calls: [call], metadata: { provider_turn_id: call.provider_turn_id }
    )
  end

  def tool_result(call = nil, error: nil)
    result = { call_id: call&.call_id || "call_1", turn_id: call&.provider_turn_id || "turn_1" }
    return result.merge(error: error) if error

    result.merge(output: "ok")
  end

  def session_args(session)
    { session: session, root_recording: @root, initiator: @initiator }
  end

  def assert_entry_points_denied(session, root)
    baseline = provider_activity
    runs = RecordingStudioAI::Run.count
    messages = %i[send_input stream cancel delete_session recover submit_tool_results].map do |name|
      denied_message(name, session, root)
    end

    assert_equal [messages.first], messages.uniq
    assert_equal baseline, provider_activity
    assert_equal runs, RecordingStudioAI::Run.count
    refute_includes messages.first, session.provider_session_id
  end

  def denied_message(name, session, root)
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      call_entry_point(name, session, root)
    end
    assert_equal "authorization", error.code
    error.message
  end

  def call_entry_point(name, session, root)
    args = { session: session, root_recording: root, initiator: @initiator }
    case name
    when :send_input
      RecordingStudioAI::Agents.send_input(**args, input: "follow-up", idempotency_key: "denied-#{root.id}")
    when :stream
      RecordingStudioAI::Agents.stream(**args) { |_event| }
    when :submit_tool_results
      RecordingStudioAI::Agents.submit_tool_results(**args, results: [tool_result]) { |_event| }
    else
      RecordingStudioAI::Agents.public_send(name, **args)
    end
  end

  def provider_activity
    [
      @fake.creates.length, @fake.submits.length, @fake.streams,
      @fake.cancels.length, @fake.deletes.length, @fake.recoveries.length, @fake.tool_results.length
    ]
  end

  def copy_run(session, root)
    copy = RecordingStudioAI::Run.find(session.run_id).dup
    copy.root_recording_id = root.id
    copy.save!
  end

  def usage
    RecordingStudioAI::Contracts::Usage.new(input_tokens: 10, output_tokens: 4, total_tokens: 14)
  end

  def completed_turn
    RecordingStudioAI::Providers::HostedTurn.new(
      provider_turn_id: "turn_1", status: "completed", usage: usage, error: nil
    )
  end

  def active_turn
    RecordingStudioAI::Providers::HostedTurn.new(
      provider_turn_id: "turn_1", status: "in_progress", usage: nil, error: nil
    )
  end

  def paused_turn
    RecordingStudioAI::Providers::HostedTurn.new(
      provider_turn_id: "turn_1", status: "in_progress", usage: usage, error: nil
    )
  end

  def assert_rejected_results(session, run, results)
    before = run.reload.attributes
    spends = @spends.length
    posted = @fake.tool_results.length
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Agents.submit_tool_results(**session_args(session), results: results) { |_event| }
    end

    assert_equal "invalid_request", error.code
    assert_equal before, run.reload.attributes
    assert_equal spends, @spends.length
    assert_equal posted, @fake.tool_results.length
  end

  def max_result_bytes
    RecordingStudioAI::Agents::Request::MAX_TOOL_RESULT_BYTES
  end

  def hosted_failure(category, code:, message:, retryable:, tool_results_rejected: false)
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: category, code: code, message: message, retryable: retryable
    )
    RecordingStudioAI::Providers::HostedAgentFailure.new(error, tool_results_rejected: tool_results_rejected)
  end

  def item(role, text, id: nil, status: "completed", turn_id: "turn_1")
    RecordingStudioAI::Providers::HostedItem.new(
      id: id || "item-#{role}", role: role, text: text, status: status, provider_turn_id: turn_id
    )
  end

  def message_event(text, item_id, turn_id: "turn_1")
    metadata = { provider_turn_id: turn_id }
    metadata[:item_id] = item_id if item_id
    RecordingStudioAI::Providers::StreamEvent.new(type: "message_completed", text: text, metadata: metadata)
  end

  def delta_event(text, item_id, turn_id: "turn_1")
    RecordingStudioAI::Providers::StreamEvent.new(
      type: "text_delta", text_delta: text, metadata: { provider_turn_id: turn_id, item_id: item_id }
    )
  end

  def turn_event_for(turn_id, usage: self.usage)
    RecordingStudioAI::Providers::StreamEvent.new(
      type: "turn_completed", usage: usage, metadata: { provider_turn_id: turn_id }
    )
  end

  def dropped_failure
    connection = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "connection", code: "network", message: "Provider connection failed.", retryable: true
    )
    RecordingStudioAI::Providers::HostedAgentFailure.new(connection, dropped: true)
  end

  def enqueued_usage_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      job[:job] == RecordingStudioAI::HostedTurnUsageJob
    end
  end

  def with_usage_logs(messages, &)
    write = ->(message = nil) { messages << message.to_s }
    Rails.logger.stub(:warn, write, &)
  end

  def delivered_ids(session)
    RecordingStudioAI::Run.find(session.run_id).reload.metadata["delivered_item_ids"]
  end

  def setup_stream_events
    @fake.events = [
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "text_delta", text_delta: "Hi", metadata: { provider_turn_id: "turn_1" }
      ),
      RecordingStudioAI::Providers::StreamEvent.new(
        type: "turn_completed", usage: usage, text: "Hi", metadata: { provider_turn_id: "turn_1" }
      )
    ]
  end
end
