# frozen_string_literal: true

require "test_helper"

class HostedAgentContractTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class FakeAdapter < RecordingStudioAI::Providers::Base
    provider_key :openai

    attr_reader :creates, :submits, :streams, :cancels, :deletes, :recoveries, :tool_results
    attr_accessor :events, :items, :stream_failure, :tool_result_failure, :default_turn, :tool_calls,
                  :on_tool_results, :recovery_failure

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
      @on_tool_results = nil
      @recovery_failure = nil
      @tool_result_failure = nil
    end

    def recovery_turns=(turns)
      @recovery_turns = turns.dup
    end

    def create_hosted_agent_session(instructions:, model:, input:, idempotency_key:, tools: nil)
      creates << {
        instructions: instructions, model: model, input: input, idempotency_key: idempotency_key, tools: tools
      }
      hosted_session("sess_1", model)
    end

    def submit_hosted_agent_input(provider_session_id:, input:, idempotency_key:)
      submits << {
        provider_session_id: provider_session_id, input: input, idempotency_key: idempotency_key
      }
      nil
    end

    def stream_hosted_agent_session(provider_session_id:, &)
      @streams += 1
      raise stream_failure if stream_failure

      events.each(&)
      provider_session_id
    end

    def cancel_hosted_agent_turn(provider_session_id:)
      cancels << provider_session_id
      nil
    end

    def delete_hosted_agent_session(provider_session_id:)
      deletes << provider_session_id
      hosted_session(provider_session_id, nil).with(status: "deleted")
    end

    def continue_hosted_agent_after_tool_results(provider_session_id:, results:, &)
      tool_results << { provider_session_id: provider_session_id, results: results }
      on_tool_results&.call
      raise tool_result_failure if tool_result_failure
      raise stream_failure if stream_failure

      events.each(&)
      provider_session_id
    end

    def recover_hosted_agent_session(provider_session_id:, provider_turn_id: nil)
      raise recovery_failure if recovery_failure

      recoveries << { provider_session_id: provider_session_id, provider_turn_id: provider_turn_id }
      RecordingStudioAI::Providers::HostedRecovery.new(
        session: hosted_session(provider_session_id, "gpt-6-astra"),
        turn: next_turn,
        items: items,
        tool_calls: next_tool_calls
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
    @configuration.usage_key_resolver = ->(**) { "ai.hosted_agent" }
    @configuration.usage_handler = ->(**kwargs) { @spends << kwargs }
    @configuration.cost_catalogs = {
      openai: { "gpt-6-astra" => { input_tokens: 3_000_000, output_tokens: 15_000_000, currency: "USD" } }
    }
    setup_stream_events
  end

  def test_create_stream_and_follow_up_record_one_run_per_turn
    session = create_session
    assert_equal :openai, session.provider
    assert_equal "sess_1", session.provider_session_id
    assert_equal "gpt-6-astra", session.model
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
    assert_equal 90, turn.cost.amount
    assert_equal "USD", turn.cost.currency
    refute_includes RecordingStudioAI::Run.column_names, "cost"
    run.reload
    assert_equal "completed", run.status
    assert_equal "turn_1", run.provider_turn_id
    assert_equal 14, run.total_tokens
    assert_equal 1, @spends.length
    assert_equal 14, @spends.first[:quantity]
    assert_equal "ai-hosted-agent-turn:turn_1", @spends.first[:idempotency_key]
    refute_includes @spends.first[:metadata].to_s, "do-not-store-this-prompt"

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
    assert_equal 14, @spends.first[:quantity]
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
    assert_equal 14, @spends.first[:quantity]
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
    assert_equal 14, @spends.first[:quantity]
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

    assert_equal 0, @fake.streams
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

  private

  def create_session(model: nil, profile: :low, tools: nil)
    args = {
      instructions: "Be brief.",
      input: "do-not-store-this-prompt",
      idempotency_key: "create-1",
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

  def item(role, text)
    RecordingStudioAI::Providers::HostedItem.new(
      id: "item-#{role}", role: role, text: text, status: "completed", provider_turn_id: "turn_1"
    )
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
