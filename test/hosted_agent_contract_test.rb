# frozen_string_literal: true

require "test_helper"

class HostedAgentContractTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class FakeAdapter < RecordingStudioAI::Providers::Base
    provider_key :openai

    attr_reader :creates, :submits, :streams, :cancels, :deletes, :recoveries
    attr_accessor :events, :items, :stream_failure, :default_turn

    def initialize(configuration: nil)
      super
      @creates = []
      @submits = []
      @streams = 0
      @cancels = []
      @deletes = []
      @recoveries = []
      @recovery_turns = []
      @events = []
      @items = []
    end

    def recovery_turns=(turns)
      @recovery_turns = turns.dup
    end

    def create_hosted_agent_session(instructions:, model:, input:, idempotency_key:)
      creates << { instructions: instructions, model: model, input: input, idempotency_key: idempotency_key }
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

    def recover_hosted_agent_session(provider_session_id:, provider_turn_id: nil)
      recoveries << { provider_session_id: provider_session_id, provider_turn_id: provider_turn_id }
      RecordingStudioAI::Providers::HostedRecovery.new(
        session: hosted_session(provider_session_id, "gpt-6-astra"),
        turn: next_turn,
        items: items
      )
    end

    private

    def next_turn
      return @recovery_turns.shift unless @recovery_turns.empty?

      default_turn
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

  def test_authorization_denial_does_not_create_a_run
    @configuration.authorization_handler = ->(**) { false }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { create_session }
    assert_equal "authorization", error.code
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty @fake.creates
  end

  private

  def create_session(model: nil, profile: :low)
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
    RecordingStudioAI::Agents.create_session(**args)
  end

  def session_args(session)
    { session: session, root_recording: @root, initiator: @initiator }
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
