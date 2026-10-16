# frozen_string_literal: true

require "test_helper"

class OpenAIHostedAgentTest < Minitest::Test
  HttpError = Class.new(StandardError) do
    attr_reader :status, :code

    def initialize(status, code = nil)
      @status = status
      @code = code
      super("raw provider body sk-live-secret")
    end
  end

  class Stream
    attr_reader :closed

    def initialize(events, error: nil)
      @events = events
      @error = error
      @closed = false
    end

    def each(&)
      @events.each(&)
      raise @error if @error
    end

    def close
      @closed = true
    end
  end

  class Events
    attr_reader :creates

    def initialize(sessions)
      @sessions = sessions
      @creates = []
    end

    def create(session_id, **params)
      raise @sessions.error if @sessions.error

      creates << [session_id, params]
      nil
    end

    def stream_streaming(_session_id)
      raise @sessions.error if @sessions.error

      @sessions.stream
    end
  end

  class Turns
    def initialize(sessions)
      @sessions = sessions
    end

    def retrieve(turn_id, session_id:)
      { id: turn_id, session_id: session_id, status: "completed", usage: token_usage }
    end

    def list(_session_id, **_params)
      Struct.new(:data).new([{ id: "turn_latest", status: "in_progress" }])
    end

    def token_usage
      { input_tokens: 3, output_tokens: 2, total_tokens: 5 }
    end
  end

  class Items
    def list(_session_id, **_params)
      Struct.new(:data, :next_page?).new(
        [{ id: "item_1", role: "assistant", text: "saved", status: "completed", turn_id: "turn_1" }],
        false
      )
    end
  end

  class Sessions
    attr_reader :events, :turns, :items, :create_params, :deleted, :retrieved
    attr_accessor :error, :stream

    def initialize
      @events = Events.new(self)
      @turns = Turns.new(self)
      @items = Items.new
      @stream = Stream.new([])
    end

    def create(**params)
      raise error if error

      @create_params = params
      { id: "sess_1", status: "idle", agent: { model: params.dig(:agent, :model) } }
    end

    def delete(session_id)
      raise error if error

      @deleted = session_id
      nil
    end

    def retrieve(session_id)
      raise error if error

      @retrieved = session_id
      { id: session_id, status: "idle", agent: { model: "gpt-6-astra" } }
    end
  end

  Client = Struct.new(:beta)

  def setup
    @sessions = Sessions.new
    agents = Struct.new(:sessions).new(@sessions)
    beta = Struct.new(:agents).new(agents)
    configuration = RecordingStudioAI::Configuration.new
    configuration.openai_client = Client.new(beta)
    @adapter = RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
  end

  def test_create_uses_no_sandbox_and_request_idempotency
    session = @adapter.create_hosted_agent_session(
      instructions: "Be brief.", model: "gpt-6-astra", input: "Hello", idempotency_key: "create-1"
    )

    params = @sessions.create_params
    assert_equal({ type: "none" }, params[:environment])
    assert_equal "gpt-6-astra", params.dig(:agent, :model)
    assert_equal "Be brief.", params.dig(:agent, :instructions)
    assert_equal "Hello", params[:input]
    assert_equal({ extra_headers: { "idempotency-key" => "create-1" } }, params[:request_options])
    refute params.key?(:store)
    assert_equal "sess_1", session.provider_session_id
    assert_equal "gpt-6-astra", session.model
  end

  def test_submit_and_cancel_use_provider_events
    @adapter.submit_hosted_agent_input(provider_session_id: "sess_1", input: "Next", idempotency_key: "turn-2")
    @adapter.cancel_hosted_agent_turn(provider_session_id: "sess_1")

    submit = @sessions.events.creates[0]
    cancel = @sessions.events.creates[1]
    assert_equal "sess_1", submit[0]
    assert_equal "turn-2", submit[1][:idempotency_key]
    assert_equal "agent.session.input.message", submit[1][:events][0][:type]
    assert_equal "Next", submit[1][:events][0].dig(:input, 0, :content, 0, :text)
    assert_equal [{ type: "agent.session.input.cancel" }], cancel[1][:events]
  end

  def test_stream_normalizes_root_events_and_skips_subagents
    @sessions.stream = Stream.new(stream_events)

    events = []
    @adapter.stream_hosted_agent_session(provider_session_id: "sess_1") { |event| events << event }

    assert @sessions.stream.closed
    assert_equal %w[text_delta message_completed turn_completed], events.map(&:type)
    assert_equal "Hi", events[0].text_delta
    assert_equal "Hi", events[1].text
    assert_equal 5, events[2].usage.total_tokens
    assert_equal "agent.session.turn.output_text.delta", events[0].metadata["provider_type"]
    refute_includes events.map { |event| event.text_delta.to_s + event.text.to_s }.join, "hidden"
    assert_nil events[0].metadata[:raw_response]
  end

  def test_delete_and_recover_read_saved_state
    deleted = @adapter.delete_hosted_agent_session(provider_session_id: "sess_1")
    recovery = @adapter.recover_hosted_agent_session(provider_session_id: "sess_1", provider_turn_id: "turn_1")

    assert_equal "sess_1", @sessions.deleted
    assert_equal "deleted", deleted.status
    assert_equal "sess_1", recovery.session.provider_session_id
    assert_equal "turn_1", recovery.turn.provider_turn_id
    assert_equal "saved", recovery.items.first.text
    assert_equal 5, recovery.turn.usage.total_tokens
  end

  def test_provider_errors_map_to_neutral_categories_without_raw_bodies
    assert_mapped(401, nil, "authentication", "invalid_credentials")
    assert_mapped(429, "rate_limit_exceeded", "rate_limit", "rate_limit_exceeded")
    assert_mapped(404, "model_not_found", "unsupported_model", "model_not_found")
    assert_mapped(404, "session_expired", "invalid_session", "session_expired")
    assert_mapped(503, nil, "provider_unavailable", "503")
  end

  def test_timeout_and_network_errors_are_neutral
    @sessions.error = Timeout::Error.new("raw timeout sk-live-secret")
    failure = assert_raises(RecordingStudioAI::Providers::HostedAgentFailure) { create_session }
    assert_equal "timeout", failure.error.category
    refute failure.dropped?
    refute_includes failure.message, "sk-live-secret"

    @sessions.error = Errno::ECONNRESET.new
    failure = assert_raises(RecordingStudioAI::Providers::HostedAgentFailure) do
      @adapter.stream_hosted_agent_session(provider_session_id: "sess_1") { |_event| }
    end
    assert_equal "connection", failure.error.category
    assert_equal "network", failure.error.code
    assert failure.dropped?
    refute_includes failure.message, "sk-"
  end

  def test_unexpected_errors_propagate
    @sessions.error = RuntimeError.new("boom")
    assert_raises(RuntimeError) { create_session }
  end

  private

  def stream_events
    [
      {
        type: "agent.session.turn.output_text.delta",
        delta: "hidden",
        turn_id: "sub_turn",
        turn: { id: "sub_turn", subagent_id: "sub_1" }
      },
      {
        type: "agent.session.turn.output_text.delta",
        delta: "Hi",
        turn_id: "turn_1",
        item_id: "item_1",
        output_index: 0,
        content_index: 0
      },
      { type: "agent.session.turn.output_text.done", text: "Hi", turn_id: "turn_1" },
      {
        type: "agent.session.turn.completed",
        turn_id: "turn_1",
        usage: { input_tokens: 3, output_tokens: 2, total_tokens: 5 },
        turn: { id: "turn_1" }
      }
    ]
  end

  def create_session
    @adapter.create_hosted_agent_session(
      instructions: nil, model: "gpt-6-astra", input: "Hello", idempotency_key: "create-1"
    )
  end

  def assert_mapped(status, code, category, expected_code)
    @sessions.error = HttpError.new(status, code)
    failure = assert_raises(RecordingStudioAI::Providers::HostedAgentFailure) do
      @adapter.submit_hosted_agent_input(provider_session_id: "sess_1", input: "Hi", idempotency_key: "k")
    end
    assert_equal category, failure.error.category
    assert_equal expected_code, failure.error.code
    refute_includes failure.error.message, "sk-live-secret"
    refute_includes failure.message, "raw provider"
  end
end
