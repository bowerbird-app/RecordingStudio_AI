# frozen_string_literal: true

require "test_helper"

class WebhooksBatchRefreshTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)
  Endpoint = Struct.new(:recording_studio_recording)
  Recording = Struct.new(:id, :root_recording, keyword_init: true) do
    def root_recording_or_self
      root_recording || self
    end
  end
  ActionContext = Struct.new(:payload, :endpoint, :inbound_event, keyword_init: true)

  class BatchProvider < RecordingStudioAI::Providers::Base
    attr_reader :refreshes
    attr_accessor :submit_result, :refresh_result

    def initialize(*)
      super
      @refreshes = []
      @submit_result = RecordingStudioAI::Providers::BatchResult.new(
        status: "submitted", provider_batch_id: "batch_openai_1"
      )
      @refresh_result = RecordingStudioAI::Providers::BatchResult.new(
        status: "completed",
        provider_batch_id: "batch_openai_1",
        items: [
          RecordingStudioAI::Providers::BatchItemResult.new(
            reference: "item-1",
            status: "completed",
            text: "done",
            finish_reason: "stop",
            usage: RecordingStudioAI::Contracts::Usage.new(
              input_tokens: 1, output_tokens: 1, total_tokens: 2
            )
          )
        ]
      )
    end

    def submit_batch(*)
      @submit_result
    end

    def refresh_batch(batch:, candidate:)
      refreshes << [batch, candidate]
      refresh_result
    end

    def cancel_batch(*)
      refresh_result
    end
  end

  def persistence_schema
    :hardened
  end

  def reset_persistence_columns?
    true
  end

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @other_root = Actor.new(create_recording_id)
    @initiator = Actor.new(41)
    @system_actor = Actor.new(7)
    @provider = BatchProvider.new
    isolate_configuration!(configured_configuration)
  end

  def test_openai_payload_extracts_batch_and_event_ids
    payload = {
      "id" => "evt_123",
      "type" => "batch.completed",
      "data" => { "id" => "batch_openai_1" }
    }

    assert_equal "batch_openai_1", RecordingStudioAI::Webhooks::OpenaiBatchPayload.provider_batch_id(payload)
    assert_equal "evt_123", RecordingStudioAI::Webhooks::OpenaiBatchPayload.event_id(payload)
    assert RecordingStudioAI::Webhooks::OpenaiBatchPayload.batch_event?(payload)
    refute RecordingStudioAI::Webhooks::OpenaiBatchPayload.batch_event?("type" => "response.completed")
  end

  def test_openai_payload_requires_data_id
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Webhooks::OpenaiBatchPayload.provider_batch_id!("id" => "evt_1", "type" => "batch.failed")
    end

    assert_equal "invalid_request", error.code
    assert_match(/data\.id/, error.message)
  end

  def test_root_recording_from_endpoint
    nested = Recording.new(id: 99, root_recording: @root_recording)
    endpoint = Endpoint.new(nested)

    assert_equal @root_recording, RecordingStudioAI::Webhooks::RootRecording.from(endpoint)
    assert_equal @root_recording, RecordingStudioAI::Webhooks::RootRecording.from(@root_recording)
  end

  def test_refresh_batch_from_webhook_looks_up_by_provider_batch_id_and_refreshes
    submitted = submit_batch!
    authorizations = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      authorizations << { action: action, attribution: attribution, context: context }
      true
    end

    response = RecordingStudioAI.refresh_batch_from_webhook(
      provider_batch_id: "batch_openai_1",
      root_recording: @root_recording,
      initiator: @system_actor,
      request_id: "evt_123"
    )

    assert response.success?
    assert_equal "completed", response.status
    assert_equal 1, @provider.refreshes.length
    assert_equal submitted.batch.id, @provider.refreshes.first.first.id

    authorization = authorizations.find { |entry| entry[:action] == "recording_studio_ai.view_execution" }
    assert_equal "webhook", authorization[:attribution].execution_source
    assert_equal "system", authorization[:attribution].initiator_kind
    assert_equal @system_actor, authorization[:attribution].initiator
    assert_equal "evt_123", authorization[:attribution].request_id
  end

  def test_refresh_batch_from_webhook_uses_configured_initiator
    submit_batch!
    RecordingStudioAI.configuration.webhook_batch_initiator = lambda do |root_recording:, **|
      assert_equal @root_recording, root_recording
      @system_actor
    end

    response = RecordingStudioAI.refresh_batch_from_webhook(
      provider_batch_id: "batch_openai_1",
      root_recording: @root_recording
    )

    assert response.success?
    assert_equal 1, @provider.refreshes.length
  end

  def test_refresh_batch_from_webhook_requires_initiator_without_resolver
    submit_batch!

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.refresh_batch_from_webhook(
        provider_batch_id: "batch_openai_1",
        root_recording: @root_recording
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/initiator/, error.message)
  end

  def test_refresh_batch_from_webhook_rejects_unknown_provider_batch_id
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.refresh_batch_from_webhook(
        provider_batch_id: "missing",
        root_recording: @root_recording,
        initiator: @system_actor
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/not found/, error.message)
  end

  def test_refresh_batch_from_webhook_rejects_cross_root_lookup
    submit_batch!

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.refresh_batch_from_webhook(
        provider_batch_id: "batch_openai_1",
        root_recording: @other_root,
        initiator: @system_actor
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/not found/, error.message)
  end

  def test_openai_batch_completion_action_wakes_refresh
    submit_batch!
    RecordingStudioAI.configuration.webhook_batch_initiator = ->(**) { @system_actor }
    recording = Recording.new(id: @root_recording.id, root_recording: nil)
    context = ActionContext.new(
      payload: {
        "id" => "evt_99",
        "type" => "batch.completed",
        "data" => { "id" => "batch_openai_1" }
      },
      endpoint: Endpoint.new(recording)
    )

    response = RecordingStudioAI::Webhooks::OpenaiBatchCompletion.call(context)

    assert response.success?
    assert_equal 1, @provider.refreshes.length
  end

  def test_openai_recipes_require_webhooks_gem_to_register
    error = assert_raises(LoadError) do
      RecordingStudioAI::Webhooks::OpenaiProvider.register!
    end
    assert_match(/recording_studio_webhooks/, error.message)

    error = assert_raises(LoadError) do
      RecordingStudioAI::Webhooks::OpenaiBatchCompletion.register!
    end
    assert_match(/recording_studio_webhooks/, error.message)
  end

  def test_idempotent_second_webhook_wake
    submit_batch!
    args = {
      provider_batch_id: "batch_openai_1",
      root_recording: @root_recording,
      initiator: @system_actor
    }

    first = RecordingStudioAI.refresh_batch_from_webhook(**args)
    second = RecordingStudioAI.refresh_batch_from_webhook(**args)

    assert first.success?
    assert second.success?
    assert_equal 2, @provider.refreshes.length
  end

  private

  def submit_batch!
    RecordingStudioAI.submit_batch(
      items: [{ reference: "item-1", prompt: "one" }],
      provider: :test,
      root_recording: @root_recording,
      initiator: @initiator
    )
  end

  def configured_configuration
    RecordingStudioAI::Configuration.new.tap do |configuration|
      configuration.attribution_validator = ->(**) {}
      configuration.authorization_handler = ->(**) { true }
      configuration.providers[:test] = @provider
      configuration.allowed_provider_overrides = [:test]
      configuration.profiles[:medium] = [{
        provider: :test,
        model: "batch-model",
        capabilities: %i[
          generation structured_output image_input file_input
          provider_native_web_search provider_batch provider_batch_cancellation
        ]
      }]
    end
  end
end
