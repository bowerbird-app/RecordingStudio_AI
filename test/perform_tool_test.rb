# frozen_string_literal: true

require "test_helper"

class PerformToolTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(51)
    @calls = 0
    isolate_allow_all_configuration!
    isolate_tools_registry!
  end

  def test_registered_echo_tool_succeeds
    actions = []
    RecordingStudioAI.configuration.authorization_handler = lambda { |action:, **|
      actions << action
      action == "recording_studio_ai.use_custom_tool"
    }
    register_echo

    performance = RecordingStudioAI.perform_tool!(
      **tool_request(arguments: { text: "argument-body" }, metadata: { note: "visible" })
    )

    assert_predicate performance, :success?
    assert_equal({ "echo" => "argument-body" }, performance.result)
    assert_nil performance.error
    assert_equal "tool", performance.run.operation
    assert_nil performance.run.resolved_provider
    assert_nil performance.run.resolved_model
    assert_equal "completed", performance.run.status
    assert_equal ["recording_studio_ai.use_custom_tool"], actions

    invocation = performance.run.custom_tool_invocations.sole
    assert_equal({ "text" => "argument-body" }, invocation.arguments)
    assert_equal({ "echo" => "argument-body" }, invocation.result)
    assert_equal({ "note" => "visible" }, performance.run.reload.metadata)
    refute_includes performance.run.metadata.to_json, "argument-body"
    assert_equal 1, @calls
  end

  def test_unknown_tool_fails
    error = assert_raises(RecordingStudioAI::Errors::ExecutionError) do
      RecordingStudioAI.perform_tool!(**tool_request(tool: { key: :missing_tool, version: 1 }, arguments: {}))
    end

    performance = error.response
    assert_equal "failed", performance.status
    assert_equal "custom_tool_not_found", performance.error.code
    assert_equal "tool", performance.run.operation
    assert_equal "failed", performance.run.status
    assert_equal 1, performance.run.custom_tool_invocations.count

    replay = RecordingStudioAI.perform_tool(**tool_request(tool: { key: :missing_tool, version: 1 }, arguments: {}))
    assert_equal performance.run.id, replay.run.id
    assert_equal 1, RecordingStudioAI::CustomToolInvocation.count
  end

  def test_confirmation_pending_then_resume_runs_the_executor_once
    outcomes = %i[pending approved]
    RecordingStudioAI.configuration.custom_tool_confirmation_handler = ->(**) { outcomes.shift }
    register_echo(requires_confirmation: true)

    pending = RecordingStudioAI.perform_tool!(**tool_request(arguments: { text: "hello" }))

    assert_predicate pending, :awaiting_confirmation?
    refute_predicate pending, :success?
    assert_equal "running", pending.run.status
    assert_equal "awaiting_confirmation", pending.run.custom_tool_invocations.sole.status
    assert_equal 0, @calls

    resumed = RecordingStudioAI.perform_tool!(
      **tool_request(arguments: nil, resume: true, request_id: "step-1")
    )

    assert_predicate resumed, :success?
    assert_equal({ "echo" => "hello" }, resumed.result)
    assert_equal pending.run.id, resumed.run.id
    assert_equal ["hello"], @seen
    assert_equal 1, resumed.run.custom_tool_invocations.count
    assert_equal({ "text" => "hello" }, resumed.run.custom_tool_invocations.sole.arguments)
  end

  def test_resume_rejected_does_not_run_the_executor
    outcomes = [:pending, false]
    RecordingStudioAI.configuration.custom_tool_confirmation_handler = ->(**) { outcomes.shift }
    register_echo(requires_confirmation: true)

    RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "hello" }))
    rejected = RecordingStudioAI.perform_tool(**tool_request(arguments: nil, resume: true))

    assert_equal "rejected", rejected.status
    assert_equal "custom_tool_confirmation_rejected", rejected.error.code
    refute_predicate rejected, :success?
    assert_equal "failed", rejected.run.status
    assert_equal 0, @calls
    assert_empty @seen

    replay = RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "hello" }))
    assert_equal rejected.run.id, replay.run.id
    assert_equal "rejected", replay.status
    assert_equal 0, @calls
  end

  def test_repeat_request_id_does_not_run_twice
    register_echo

    first = RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "hi" }))
    second = RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "other" }))

    assert_equal first.run.id, second.run.id
    assert_equal({ "echo" => "hi" }, second.result)
    assert_equal 1, @calls
    assert_equal 1, RecordingStudioAI::Run.where(operation: "tool").count
  end

  def test_blank_request_id_runs_the_tool_again
    register_echo

    2.times { RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "hi" }, request_id: nil)) }

    assert_equal 2, @calls
    assert_equal 2, RecordingStudioAI::Run.where(operation: "tool").count
  end

  def test_result_size_limit_still_applies
    RecordingStudioAI.configuration.maximum_custom_tool_result_size = 4
    register_echo(executor: ->(_arguments, _context) { "abcdef" })

    performance = RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "hi" }, request_id: "too-big"))

    assert_equal "failed", performance.status
    assert_equal "custom_tool_result_too_large", performance.error.code
    assert_equal "failed", performance.run.status
    assert_equal 1, @calls
  end

  def test_timeout_still_applies
    RecordingStudioAI.configuration.custom_tool_timeout = 0.05
    register_echo(executor: lambda { |_arguments, _context|
      sleep 0.3
      { "echo" => "late" }
    })

    performance = RecordingStudioAI.perform_tool(**tool_request(arguments: { text: "hi" }, request_id: "slow"))

    assert_equal "failed", performance.status
    assert_equal "custom_tool_timeout", performance.error.code
    assert_equal 1, @calls
  end

  def test_resume_without_a_run_fails
    register_echo

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.perform_tool(**tool_request(arguments: nil, resume: true, request_id: "missing"))
    end

    assert_equal "invalid_request", error.code
    assert_equal "no tool run to resume", error.message
    assert_equal 0, RecordingStudioAI::Run.count

    missing_id = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.perform_tool(**tool_request(arguments: nil, resume: true, request_id: nil))
    end
    assert_equal "no tool run to resume", missing_id.message
  end

  private

  def register_echo(executor: nil, requires_confirmation: false)
    @seen = []
    supplied = executor
    RecordingStudioAI.tools.register(
      key: :echo_text,
      version: 1,
      name: "Echo text",
      description: "Returns the text it was given.",
      use_when: "The caller wants the text back.",
      do_not_use_when: "The text is empty.",
      parameters: [
        { name: :text, type: :string, required: true, description: "Text to echo." }
      ],
      returns: "The echoed text.",
      cost: :negligible,
      latency: :instant,
      read_only: true,
      destructive: false,
      requires_confirmation: requires_confirmation,
      idempotent: true,
      executor_label: "Echo.text",
      executor: lambda { |arguments, context|
        @calls += 1
        if supplied
          supplied.call(arguments, context)
        else
          @seen << arguments.fetch("text")
          { "echo" => arguments.fetch("text") }
        end
      }
    )
  end

  def tool_request(**overrides)
    {
      tool: { key: :echo_text, version: 1 },
      purpose: "agent_step",
      root_recording: @root_recording,
      context_recording: @root_recording,
      initiator: @initiator,
      initiator_kind: :agent,
      executor: @initiator,
      execution_source: :job,
      request_id: "step-1"
    }.merge(overrides)
  end
end
