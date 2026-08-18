# frozen_string_literal: true

require "test_helper"

class PhaseFourAuthorizationTest < RecordingStudioAI::Test::IsolatedCase
  Identifiable = Struct.new(:id)

  def setup
    @root_recording = Identifiable.new("root-1")
    @context_recording = Identifiable.new("ctx-1")
    @initiator = Identifiable.new("user-1")
    @executor = Identifiable.new("exec-1")
    @impersonator = Identifiable.new("imp-1")
    isolate_configuration!
    RecordingStudioAI.configuration.attribution_validator = ->(**) {}
  end

  def test_action_map_matches_recording_studio_accessible_contract
    expected = {
      execute: "recording_studio_ai.execute",
      use_provider_native_tool: "recording_studio_ai.use_provider_native_tool",
      use_custom_tool: "recording_studio_ai.use_custom_tool",
      confirm_custom_tool: "recording_studio_ai.confirm_custom_tool",
      submit_batch: "recording_studio_ai.submit_batch",
      cancel_batch: "recording_studio_ai.cancel_batch",
      view_execution: "recording_studio_ai.view_execution",
      view_sensitive_execution: "recording_studio_ai.view_sensitive_execution",
      view_retained_response: "recording_studio_ai.view_retained_response"
    }

    assert_equal expected, RecordingStudioAI::Authorization::ACTIONS
  end

  def test_generate_authorizes_before_execution_response
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << { action: action, attribution: attribution, context: context }
      false
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Summarize this",
        root_recording: @root_recording,
        context_recording: @context_recording,
        initiator: @initiator,
        executor: @executor,
        impersonator: @impersonator,
        initiator_kind: :agent,
        execution_source: :api,
        request_id: "req-1",
        job_id: "job-1"
      )
    end

    assert_equal "authorization", error.code
    assert_equal 1, calls.length
    assert_equal "recording_studio_ai.execute", calls.first[:action]
    assert_equal "generation", calls.first[:context]["operation"]
    assert_equal "medium", calls.first[:context]["profile"]

    attribution = calls.first[:attribution]
    assert_instance_of RecordingStudioAI::Contracts::Attribution, attribution
    assert_equal(
      {
        root_recording_id: "root-1",
        context_recording_id: "ctx-1",
        initiator_id: "user-1",
        initiator_kind: "agent",
        executor_id: "exec-1",
        impersonator_id: "imp-1",
        execution_source: "api",
        request_id: "req-1",
        job_id: "job-1"
      },
      attribution.to_h
    )
  end

  def test_authorization_requires_literal_true
    truthy_policy_result = Object.new
    truthy_policy_result.define_singleton_method(:==) { |other| other == true }
    RecordingStudioAI.configuration.authorization_handler = ->(**) { truthy_policy_result }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Authorization.authorize!(:execute, attribution: @initiator)
    end

    assert_equal "authorization", error.code
  end

  def test_stream_authorizes_execute
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << { action: action, attribution: attribution, context: context }
      false
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(stream: true, 
        prompt: "Stream this",
        root_recording: @root_recording,
        initiator: @initiator
      ) { |_event| }
    end

    assert_equal "authorization", error.code
    assert_equal 1, calls.length
    assert_equal "recording_studio_ai.execute", calls.first[:action]
    assert_equal "stream", calls.first[:context]["operation"]
  end

  def test_submit_batch_authorizes_submit_batch
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << { action: action, attribution: attribution, context: context }
      false
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item-1", prompt: "Summarize" }],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "authorization", error.code
    assert_equal 1, calls.length
    assert_equal "recording_studio_ai.submit_batch", calls.first[:action]
    assert_equal "batch_submit", calls.first[:context]["operation"]
    assert_equal 1, calls.first[:context]["item_count"]
  end

  def test_refresh_batch_authorizes_view_execution
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << { action: action, attribution: attribution, context: context }
      false
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.refresh_batch(
        batch_id: "batch-123",
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "authorization", error.code
    assert_equal 1, calls.length
    assert_equal "recording_studio_ai.view_execution", calls.first[:action]
    assert_equal "batch_refresh", calls.first[:context]["operation"]
    assert_equal "batch-123", calls.first[:context]["batch_id"]
  end

  def test_cancel_batch_authorizes_cancel_batch
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << { action: action, attribution: attribution, context: context }
      false
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.cancel_batch(
        batch_id: "batch-123",
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "authorization", error.code
    assert_equal 1, calls.length
    assert_equal "recording_studio_ai.cancel_batch", calls.first[:action]
    assert_equal "batch_cancel", calls.first[:context]["operation"]
    assert_equal "batch-123", calls.first[:context]["batch_id"]
  end

  def test_attribution_rejects_invalid_initiator_kind
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Summarize",
        root_recording: @root_recording,
        initiator: @initiator,
        initiator_kind: "invalid"
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/initiator_kind/, error.message)
  end

  def test_attribution_rejects_invalid_execution_source
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Summarize",
        root_recording: @root_recording,
        initiator: @initiator,
        execution_source: "desktop"
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/execution_source/, error.message)
  end

  def test_initiator_kind_defaults_to_user
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << { action: action, attribution: attribution, context: context }
      true
    end

    RecordingStudioAI.generate(
      prompt: "Summarize",
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_equal "user", calls.first[:attribution].initiator_kind
  end
end
