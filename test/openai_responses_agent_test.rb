# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock"

class OpenAIResponsesAgentTest < Minitest::Test
  include RecordingStudioAI::Test::Persistence

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

  class Items
    def initialize(world)
      @world = world
    end

    def list(*)
      @world.log << [:items_list]
      [
        { id: "old_1", type: "message", role: "assistant", content: [{ text: "turn one" }] },
        { id: "old_2", type: "message", role: "assistant", content: [{ text: "turn two" }] }
      ]
    end
  end

  class Conversations
    def initialize(world)
      @world = world
      @items = Items.new(world)
    end

    attr_reader :items

    def create(metadata:)
      @world.log << [:conversation_create, metadata]
      @world.metadata = metadata.transform_keys(&:to_s)
      { id: "conv_1", object: "conversation", created_at: 1, metadata: @world.metadata }
    end

    def retrieve(conversation_id)
      @world.log << [:conversation_retrieve, conversation_id]
      { id: conversation_id, object: "conversation", created_at: 1, metadata: @world.metadata }
    end

    def update(conversation_id, metadata:)
      @world.log << [:conversation_update, conversation_id, metadata]
      raise "update failed" if @world.fail_update

      @world.metadata = metadata.transform_keys(&:to_s)
      { id: conversation_id, object: "conversation", created_at: 1, metadata: @world.metadata }
    end

    def delete(conversation_id)
      @world.log << [:conversation_delete, conversation_id]
      nil
    end
  end

  class Responses
    def initialize(world)
      @world = world
    end

    def stream_raw(**params)
      @world.log << [:stream_raw, params]
      raise @world.stream_error if @world.stream_error

      id = @world.next_response_id
      Stream.new([
                   {
                     type: "response.created",
                     sequence_number: 2,
                     response: {
                       id: id, status: "in_progress", model: "gpt-5.6-sol",
                       instructions: params[:instructions], output: []
                     }
                   }
                 ])
    end

    def retrieve(response_id)
      @world.log << [:retrieve, response_id]
      if @world.holds_left.to_i.positive?
        @world.holds_left -= 1
        @world.held << :blocked
        @world.hold.pop
      end
      @world.response_for(response_id)
    end

    def retrieve_streaming(response_id, **params)
      @world.log << [:retrieve_streaming, response_id, params]
      raise @world.stream_error if @world.stream_error

      Stream.new(@world.resume_events)
    end

    def cancel(response_id)
      @world.log << [:cancel, response_id]
      nil
    end

    def delete(response_id)
      @world.log << [:delete_response, response_id]
      raise "delete failed" if @world.fail_delete

      nil
    end
  end

  class World
    attr_accessor :metadata, :fail_update, :fail_delete, :stream_error, :resume_events, :statuses, :output,
                  :output_text, :incomplete_reason, :response_model, :holds_left, :hold, :held
    attr_reader :log

    def initialize
      @log = []
      @metadata = {}
      @statuses = Hash.new("completed")
      @output = []
      @output_text = "Hi"
      @resume_events = []
      @response_ids = []
      @response_model = "gpt-5.6-sol"
    end

    def next_response_id
      id = "resp_#{@response_ids.length + 1}"
      @response_ids << id
      id
    end

    def response_for(response_id)
      {
        id: response_id,
        status: @statuses[response_id],
        model: @response_model,
        instructions: "Be brief.",
        output: output,
        output_text: output_text,
        incomplete_details: incomplete_reason ? { reason: incomplete_reason } : nil,
        usage: { input_tokens: 3, output_tokens: 2, total_tokens: 5 }
      }
    end
  end

  class BetaEvents
    def initialize(world)
      @world = world
    end

    def create(*)
      @world.log << [:beta_submit]
      nil
    end
  end

  class BetaSessions
    def initialize(world)
      @events = BetaEvents.new(world)
    end

    attr_reader :events
  end

  class BetaAgents
    def initialize(world)
      @sessions = BetaSessions.new(world)
    end

    attr_reader :sessions
  end

  class BetaClient
    def initialize(world)
      @agents = BetaAgents.new(world)
    end

    attr_reader :agents
  end

  Client = Struct.new(:conversations, :responses, :beta)

  def setup
    RecordingStudioAI::Test::Persistence.load!
    connect_shared_sqlite!
    bootstrap_host_tables!
    migrate_persistence!
    RecordingStudioAI::HostedResponse.reset_column_information
    @world = World.new
    configuration = RecordingStudioAI::Configuration.new
    configuration.hosted_agent_backend = :responses
    configuration.openai_client = Client.new(
      Conversations.new(@world), Responses.new(@world), BetaClient.new(@world)
    )
    configuration.retry_sleeper = ->(_seconds) {}
    @adapter = RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
    @configuration = configuration
  end

  def teardown
    disconnect_sqlite!
    FileUtils.rm_f(@sqlite_path) if @sqlite_path
  end

  def test_create_streams_in_the_background_and_stores_the_created_sequence
    session = create_session

    params = stream_params
    assert_equal true, params[:stream]
    assert_equal true, params[:background]
    assert_equal true, params[:store]
    assert_equal 4, params[:max_tool_calls]
    assert_equal [{ type: "compaction", compact_threshold: 200_000 }], params[:context_management]
    refute params.key?(:idempotency_key)
    refute params.key?(:request_options)
    assert_equal "conv_1", session.provider_session_id
    assert_equal "gpt-6-astra", session.model
    stored = RecordingStudioAI::HostedResponse.latest_for("conv_1")
    assert_equal "resp_1", stored.response_id
    assert_equal 2, stored.sequence_number
    assert_equal false, stored.text_emitted
    assert_equal "resp_1", @world.metadata["response_id"]
    refute @world.metadata.key?("response_ids")
    refute @world.metadata.key?("sequence_number")
    assert_operator @world.metadata.values.join.bytesize, :<, 512
  end

  def test_create_prefers_the_stored_host_model_over_the_billed_model
    @configuration.hosted_agent_mcp_servers = []
    create_session(model: "gpt-5-pro")
    assert_equal "gpt-5.6-sol", stream_params[:model]
    assert_equal({ mode: "pro", effort: "high" }, stream_params[:reasoning])

    @world.response_model = "gpt-5.6-sol"
    @adapter.submit_hosted_agent_input(provider_session_id: "conv_1", input: "Next", idempotency_key: "turn-2")

    assert_equal "gpt-5-pro", @world.metadata["model"]
    assert_equal({ mode: "pro", effort: "high" }, stream_calls.last[1][:reasoning])
  end

  def test_create_cancels_the_started_response_before_deleting_the_conversation
    @world.fail_update = true

    assert_raises(RuntimeError) { create_session }

    cancel_at = @world.log.index { |entry| entry[0] == :cancel && entry[1] == "resp_1" }
    delete_at = @world.log.index { |entry| entry[0] == :conversation_delete }
    assert cancel_at
    assert delete_at
    assert_operator cancel_at, :<, delete_at
    refute(@world.log.any? { |entry| entry[0] == :stream_raw && entry[1].key?(:idempotency_key) })
  end

  def test_submit_raises_turn_active_until_the_latest_response_finishes
    create_session
    @world.statuses["resp_1"] = "in_progress"

    error = assert_raises(RecordingStudioAI::Providers::HostedAgentFailure) do
      @adapter.submit_hosted_agent_input(provider_session_id: "conv_1", input: "Next", idempotency_key: "turn-2")
    end

    assert_equal "invalid_request", error.error.category
    assert_equal "turn_active", error.error.code
    assert_equal(1, @world.log.count { |entry| entry[0] == :stream_raw })
  end

  def test_submit_locks_per_session_until_the_first_call_finishes
    create_session
    @world.statuses["resp_1"] = "completed"
    @world.hold = Queue.new
    @world.held = Queue.new
    @world.holds_left = 1

    first = Thread.new do
      @adapter.submit_hosted_agent_input(provider_session_id: "conv_1", input: "One", idempotency_key: "a")
    end
    assert_equal :blocked, @world.held.pop(timeout: 2)
    second = Thread.new do
      @adapter.submit_hosted_agent_input(provider_session_id: "conv_1", input: "Two", idempotency_key: "b")
    end
    wait_until { second.status == "sleep" }
    assert_equal(1, @world.log.count { |entry| entry[0] == :retrieve })
    @world.hold << true
    first.join
    second.join
    assert_equal(3, @world.log.count { |entry| entry[0] == :stream_raw })
  end

  def test_resume_skips_events_at_or_before_the_stored_sequence
    create_session
    @world.resume_events = [
      { type: "response.output_text.delta", sequence_number: 2, delta: "old" },
      { type: "response.output_text.delta", sequence_number: 3, delta: "new" },
      { type: "response.completed", sequence_number: 4, response: completed_response("resp_1") }
    ]

    events = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| events << event }

    streaming = @world.log.select { |entry| entry[0] == :retrieve_streaming }
    assert_equal({ starting_after: 2 }, streaming.last[2])
    assert_equal %w[text_delta turn_completed], events.map(&:type)
    assert_equal "new", events[0].text_delta
    assert_equal 4, RecordingStudioAI::HostedResponse.latest_for("conv_1").sequence_number
  end

  def test_reconnect_does_not_repeat_text_after_a_poll
    create_session
    @world.stream_error = Timeout::Error.new("raw")
    @world.output_text = "saved reply"

    events = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| events << event }
    assert_equal %w[message_completed turn_completed], events.map(&:type)
    assert_equal true, RecordingStudioAI::HostedResponse.latest_for("conv_1").text_emitted

    again = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| again << event }
    assert_equal %w[turn_completed], again.map(&:type)
  end

  def test_recovery_includes_only_this_turns_output
    create_session
    @world.output = [
      { id: "msg_3", type: "message", role: "assistant", status: "completed", content: [{ text: "turn three" }] }
    ]

    recovery = @adapter.recover_hosted_agent_session(provider_session_id: "conv_1", provider_turn_id: "resp_1")

    assert_equal ["turn three"], recovery.items.map(&:text)
    refute_includes @world.log.map(&:first), :items_list
  end

  def test_stream_follows_a_replacement_response_id
    create_session
    @world.resume_events = [
      {
        type: "response.output_text.delta", sequence_number: 3, delta: "Hi",
        response: { id: "resp_2" }
      },
      {
        type: "response.completed", sequence_number: 4,
        response: completed_response("resp_2")
      }
    ]

    events = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| events << event }

    assert_equal(%w[resp_2 resp_2], events.map { |event| event.metadata["provider_turn_id"] })
    assert_equal "resp_2", @world.metadata["response_id"]
    ids = RecordingStudioAI::HostedResponse.response_ids_for("conv_1")
    assert_includes ids, "resp_1"
    assert_includes ids, "resp_2"
    refute @world.metadata.key?("response_ids")
  end

  def test_approval_and_tool_step_limit_fail_the_turn
    create_session
    @world.resume_events = [
      {
        type: "response.incomplete", sequence_number: 3,
        response: completed_response("resp_1").merge(
          status: "incomplete",
          output: [{ type: "mcp_approval_request", id: "apr_1" }]
        )
      }
    ]
    events = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| events << event }
    assert_equal "failed", events.last.type
    assert_equal "mcp_approval_required", events.last.error.code
    refute_includes events.map(&:type), "turn_completed"

    RecordingStudioAI::HostedResponse.latest_for("conv_1").update!(sequence_number: 2, text_emitted: false)
    @world.resume_events = [
      {
        type: "response.completed", sequence_number: 5,
        response: completed_response("resp_1").merge(
          status: "completed",
          output: [
            { type: "mcp_call", id: "call_1" },
            { type: "web_search_call", id: "call_2" },
            { type: "file_search_call", id: "call_3" },
            { type: "code_interpreter_call", id: "call_4" },
            { type: "function_call", id: "fn_1" }
          ]
        )
      }
    ]
    limited = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| limited << event }
    assert_equal "tool_step_limit", limited.last.error.code
    assert_equal "failed", limited.last.type
  end

  def test_cancel_and_delete_reach_the_stored_responses
    create_session
    RecordingStudioAI::HostedResponse.record!(provider_session_id: "conv_1", response_id: "resp_old")
    @world.statuses["resp_old"] = "completed"
    @world.statuses["resp_1"] = "in_progress"

    @adapter.cancel_hosted_agent_turn(provider_session_id: "conv_1")
    assert_equal ["resp_1"], log_values(:cancel)

    deleted = @adapter.delete_hosted_agent_session(provider_session_id: "conv_1")
    cancelled = log_values(:cancel)
    removed = log_values(:delete_response)
    assert_includes cancelled, "resp_1"
    refute_includes cancelled, "resp_old"
    assert_includes removed, "resp_old"
    assert_includes removed, "resp_1"
    refute_includes removed, "resp_untracked"
    assert(@world.log.any? { |entry| entry == [:conversation_delete, "conv_1"] })
    assert_equal "deleted", deleted.status
  end

  def test_responses_backend_rejects_an_id_that_is_not_a_known_prefix
    error = assert_raises(RecordingStudioAI::Providers::HostedAgentFailure) do
      @adapter.submit_hosted_agent_input(provider_session_id: "legacy_1", input: "Hi", idempotency_key: "k")
    end

    assert_equal "invalid_session", error.error.category
    assert_equal "legacy_beta_session", error.error.code
    assert_empty @world.log
  end

  def test_sess_id_stays_on_the_beta_adapter
    @configuration.hosted_agent_backend = :responses

    @adapter.submit_hosted_agent_input(provider_session_id: "sess_9", input: "Hi", idempotency_key: "k")

    assert_includes @world.log.map(&:first), :beta_submit
    refute_includes @world.log.map(&:first), :stream_raw
  end

  def test_submit_cancels_the_response_when_remember_fails
    create_session
    @world.statuses["resp_1"] = "completed"
    @world.fail_update = true

    assert_raises(RuntimeError) do
      @adapter.submit_hosted_agent_input(provider_session_id: "conv_1", input: "Next", idempotency_key: "turn-2")
    end

    assert_includes log_values(:cancel), "resp_2"
    refute(@world.log.any? { |entry| entry[0] == :conversation_delete })
  end

  def test_delete_reports_partial_when_a_response_delete_fails
    create_session
    @world.fail_delete = true

    deleted = @adapter.delete_hosted_agent_session(provider_session_id: "conv_1")

    assert_equal "partial", deleted.status
  end

  def test_many_response_ids_stay_out_of_conversation_metadata
    create_session
    ids = Array.new(40) { |index| "resp_#{index.to_s.rjust(4, '0')}_padding" }
    ids.each do |response_id|
      RecordingStudioAI::HostedResponse.record!(provider_session_id: "conv_1", response_id: response_id)
    end

    joined = RecordingStudioAI::HostedResponse.response_ids_for("conv_1").join(",")
    assert_operator joined.bytesize, :>, 512
    refute @world.metadata.key?("response_ids")
    assert_operator @world.metadata.values.join.bytesize, :<, 512
  end

  def test_polling_waits_and_skips_text_while_the_response_is_in_progress
    create_session
    @world.stream_error = Timeout::Error.new("raw")
    @world.statuses["resp_1"] = "in_progress"
    @world.output_text = "not yet"
    delays = []
    @configuration.retry_sleeper = ->(seconds) { delays << seconds }

    events = []
    @adapter.stream_hosted_agent_session(provider_session_id: "conv_1") { |event| events << event }

    assert_empty events
    assert_equal [0.5, 1, 2, 4], delays
  end

  def test_mcp_tools_send_authorization_and_do_not_auto_approve
    @configuration.hosted_agent_mcp_servers = [
      {
        server_url: "https://mcp.example.com/mcp",
        server_label: "example",
        authorization: "Bearer mcp-token",
        require_approval: "never",
        allowed_tools: ["search"]
      }
    ]
    create_session

    tool = stream_params[:tools].first
    assert_equal "mcp", tool[:type]
    assert_equal "Bearer mcp-token", tool[:authorization]
    assert_equal "never", tool[:require_approval]
    refute tool.key?(:headers)
  end

  private

  # A file database lets a second thread see the migrated tables and wait on
  # the writer lock. :memory: is private to one connection.
  def connect_shared_sqlite!
    @sqlite_path = File.join(Dir.tmpdir, "rsai-responses-#{object_id}.sqlite3")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: @sqlite_path, pool: 5)
  end

  def create_session(model: "gpt-6-astra")
    @adapter.create_hosted_agent_session(
      instructions: "Be brief.", model: model, input: "Hello", idempotency_key: "create-1"
    )
  end

  def stream_params
    stream_calls.last[1]
  end

  def stream_calls
    @world.log.select { |entry| entry[0] == :stream_raw }
  end

  def log_values(kind)
    @world.log.select { |entry| entry[0] == kind }.map { |entry| entry[1] }
  end

  def completed_response(response_id)
    @world.response_for(response_id).merge(status: "completed")
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      return if yield
      raise "timed out waiting for the session lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end
end

class OpenAIResponsesWebMockTest < Minitest::Test
  include WebMock::API
  include RecordingStudioAI::Test::Persistence

  def setup
    RecordingStudioAI::Test::Persistence.load!
    connect_sqlite_memory!
    bootstrap_host_tables!
    migrate_persistence!
    RecordingStudioAI::HostedResponse.reset_column_information
    WebMock.enable!
    WebMock.disable_net_connect!
    WebMock.reset!
    configuration = RecordingStudioAI::Configuration.new
    configuration.hosted_agent_backend = :responses
    configuration.openai_api_key = "test-key"
    @adapter = RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
  end

  def teardown
    WebMock.reset!
    WebMock.disable!
    disconnect_sqlite!
  end

  def test_create_body_sets_stream_and_background
    stub_request(:post, "https://api.openai.com/v1/conversations").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { id: "conv_web", object: "conversation", created_at: 1, metadata: { model: "gpt-6-astra" } }.to_json
    )
    stub_request(:post, "https://api.openai.com/v1/responses").to_return(
      status: 200,
      headers: { "Content-Type" => "text/event-stream" },
      body: created_event
    )
    stub_request(:post, "https://api.openai.com/v1/conversations/conv_web").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { id: "conv_web", object: "conversation", created_at: 1, metadata: {} }.to_json
    )

    error = nil
    begin
      @adapter.create_hosted_agent_session(
        instructions: "Be brief.", model: "gpt-6-astra", input: "Hello", idempotency_key: "create-1"
      )
    rescue StandardError => e
      error = e
    end
    if WebMock::RequestRegistry.instance.requested_signatures.hash.empty?
      flunk(error ? "#{error.class}: #{error.message}" : "create made no HTTP request")
    end

    assert_requested :post, "https://api.openai.com/v1/responses" do |request|
      body = JSON.parse(request.body)
      assert_equal true, body["stream"]
      assert_equal true, body["background"]
      assert_equal 4, body["max_tool_calls"]
      assert_equal "compaction", body.dig("context_management", 0, "type")
      refute header?(request, "Idempotency-Key")
    end
    assert_requested :post, "https://api.openai.com/v1/conversations" do |request|
      refute header?(request, "Idempotency-Key")
    end
  end

  private

  def header?(request, name)
    request.headers.keys.any? { |key| key.casecmp?(name) }
  end

  def created_event
    response = {
      id: "resp_web", access_programs: nil, created_at: 1.0, error: nil, incomplete_details: nil,
      instructions: "Be brief.", metadata: {}, model: "gpt-6-astra", object: "response", output: [],
      parallel_tool_calls: true, temperature: 1.0, tool_choice: "auto", tools: [], top_p: 1.0,
      status: "queued", background: true
    }
    payload = { type: "response.created", sequence_number: 1, response: response }
    "data: #{payload.to_json}\n\n"
  end
end
