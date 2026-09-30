# frozen_string_literal: true

require "test_helper"

class PhaseElevenProviderBatchesTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class BatchProvider < RecordingStudioAI::Providers::Base
    attr_reader :submissions, :refreshes, :cancellations
    attr_accessor :submit_result, :refresh_result, :cancel_result

    def initialize
      @submissions = []
      @refreshes = []
      @cancellations = []
      @submit_result = RecordingStudioAI::Providers::BatchResult.new(
        status: "submitted", provider_batch_id: "provider-batch-1"
      )
      @refresh_result = @submit_result
      @cancel_result = RecordingStudioAI::Providers::BatchResult.new(
        status: "cancelled", provider_batch_id: "provider-batch-1"
      )
    end

    def submit_batch(request:, candidate:)
      submissions << [request, candidate]
      submit_result
    end

    def refresh_batch(batch:, candidate:)
      refreshes << [batch, candidate]
      refresh_result
    end

    def cancel_batch(batch:, candidate:)
      cancellations << [batch, candidate]
      cancel_result
    end
  end

  class ExplodingBatchProvider < BatchProvider
    def submit_batch(request:, candidate:)
      raise "secret provider batch payload"
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
    @provider = BatchProvider.new
    isolate_configuration!(configured_configuration)
  end

  def test_submit_normalizes_and_validates_batch_items
    request = RecordingStudioAI::Contracts::RequestValidation.validate_batch_submit_request!(
      items: [{ reference: " item-1 ", messages: [{ "role" => "user", "content" => "Summarize" }],
                purpose: "summarize_page", metadata: { source: :test } }],
      provider: :test, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal "item-1", request[:items].first[:reference]
    assert_equal :test, request[:provider]
    assert_equal({ "source" => "test" }, request[:items].first[:metadata])

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "same", prompt: "one" }, { reference: " same ", prompt: "two" }],
        root_recording: @root_recording, initiator: @initiator
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item", prompt: "one", messages: [{ role: "user", content: "two" }] }],
        root_recording: @root_recording, initiator: @initiator
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item", prompt: "one", metadata: { sdk: Object.new } }],
        root_recording: @root_recording, initiator: @initiator
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item", prompt: "one", custom_tools: [{ key: "lookup", version: 1 }] }],
        root_recording: @root_recording, initiator: @initiator
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item", prompt: "one", schemma: { type: "object" } }],
        root_recording: @root_recording, initiator: @initiator
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item", prompt: "one" }], profille: :high,
        root_recording: @root_recording, initiator: @initiator
      )
    end
  end

  def test_batch_synchronization_job_forwards_explicit_attribution_and_stops_when_terminal
    calls = []
    response = Struct.new(:status).new("completed")

    RecordingStudioAI.stub(:refresh_batch, lambda { |**arguments|
      calls << arguments
      response
    }) do
      result = RecordingStudioAI::BatchSynchronizationJob.perform_now(
        batch_id: "batch-1", root_recording: @root_recording, initiator: @initiator
      )

      assert_same response, result
    end

    assert_equal "batch-1", calls.first.fetch(:batch_id)
    assert_same @root_recording, calls.first.fetch(:root_recording)
    assert_same @initiator, calls.first.fetch(:initiator)
    assert_equal "job", calls.first.fetch(:execution_source).to_s
    assert calls.first.fetch(:job_id).present?
  end

  def test_batch_synchronization_job_reschedules_nonterminal_batches
    scheduled = nil
    scheduler = Object.new
    scheduler.define_singleton_method(:perform_later) { |**arguments| scheduled = arguments }
    response = Struct.new(:status).new("processing")

    RecordingStudioAI.stub(:refresh_batch, response) do
      RecordingStudioAI::BatchSynchronizationJob.stub(:set, lambda { |wait:|
        assert_equal 1.minute, wait
        scheduler
      }) do
        RecordingStudioAI::BatchSynchronizationJob.perform_now(
          batch_id: "batch-1", root_recording: @root_recording, initiator: @initiator
        )
      end
    end

    assert_equal "batch-1", scheduled.fetch(:batch_id)
    assert_same @root_recording, scheduled.fetch(:root_recording)
    assert_same @initiator, scheduled.fetch(:initiator)
  end

  def test_batch_synchronization_job_preserves_complete_attribution
    impersonator = Actor.new(99)
    calls = []
    response = Struct.new(:status).new("completed")

    RecordingStudioAI.stub(:refresh_batch, lambda { |**arguments|
      calls << arguments
      response
    }) do
      RecordingStudioAI::BatchSynchronizationJob.perform_now(
        batch_id: "batch-1", root_recording: @root_recording, initiator: @initiator,
        initiator_kind: :service, impersonator: impersonator
      )
    end

    assert_equal :service, calls.first.fetch(:initiator_kind)
    assert_same impersonator, calls.first.fetch(:impersonator)
  end

  def test_refresh_batch_async_enqueues_the_configured_polling_job
    scheduled = nil
    polling_job = Class.new do
      define_singleton_method(:perform_later) { |**arguments| scheduled = arguments }
    end
    RecordingStudioAI.configuration.batch_synchronization_job = polling_job

    RecordingStudioAI.refresh_batch_async(
      batch_id: "batch-1", root_recording: @root_recording, initiator: @initiator
    )

    assert_equal "batch-1", scheduled.fetch(:batch_id)
    assert_same @root_recording, scheduled.fetch(:root_recording)
    assert_same @initiator, scheduled.fetch(:initiator)
    assert_equal "job", scheduled.fetch(:execution_source).to_s
  end

  def test_item_capabilities_are_not_dropped_before_resolution
    RecordingStudioAI.configuration.profiles[:medium].first[:capabilities] = %i[generation provider_batch]

    response = RecordingStudioAI.submit_batch(
      items: [{ reference: "item", prompt: "one", schema: { type: "object" } }],
      root_recording: @root_recording, initiator: @initiator
    )

    refute response.success?
    assert_equal "unsupported_capability", response.error.category
    assert_equal 0, RecordingStudioAI::Batch.count
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty @provider.submissions
  end

  def test_batch_web_search_authorization_receives_batch_attribution
    authorizations = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      authorizations << [action, attribution, context]
      true
    end

    RecordingStudioAI.submit_batch(
      items: [{ reference: "search", prompt: "search", provider_native_tools: [:web_search] }],
      provider: :test, root_recording: @root_recording, initiator: @initiator
    )

    authorization = authorizations.find do |action, _attribution, _context|
      action == "recording_studio_ai.use_provider_native_tool"
    end
    assert_same @root_recording, authorization.fetch(1).root_recording
    assert_equal "batch_submit", authorization.fetch(2).fetch("operation")
  end

  def test_submit_persists_one_batch_run_and_item_per_request_without_content
    response = submit_two_items

    assert response.success?
    assert_instance_of RecordingStudioAI::Contracts::BatchResponse, response
    assert_equal 1, RecordingStudioAI::Batch.count
    assert_equal 2, RecordingStudioAI::Run.count
    assert_equal 2, RecordingStudioAI::BatchItem.count
    assert_equal %w[first second], response.items.map(&:reference)
    RecordingStudioAI::Run.find_each do |run|
      assert_nil run.input_character_count
    end
    persisted = RecordingStudioAI::Batch.first.attributes.values +
                RecordingStudioAI::BatchItem.all.flat_map { |item| item.attributes.values } +
                RecordingStudioAI::Run.all.flat_map { |run| run.attributes.values }
    refute_includes persisted, "sensitive first prompt"
    refute_includes persisted, "sensitive second prompt"
  end

  def test_batch_persists_impersonator_attribution
    impersonator = Actor.new(99)
    response = RecordingStudioAI.submit_batch(
      items: [{ reference: "first", prompt: "one" }], root_recording: @root_recording,
      initiator: @initiator, impersonator: impersonator
    )

    assert_equal impersonator.class.name, response.batch.impersonator_type
    assert_equal impersonator.id.to_s, response.batch.impersonator_id
  end

  def test_refresh_is_idempotent_and_aggregates_reported_item_metrics
    response = submit_two_items
    @provider.refresh_result = completed_result

    first = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )
    second = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert first.success?
    assert_equal "completed", first.status
    assert_equal "answer one", first.items.first.text
    assert_equal 15, first.usage.total_tokens
    assert_nil first.cost
    assert_equal 15, second.usage.total_tokens
    assert_nil second.cost
    assert_equal "answer one", second.items.first.text
    assert_equal 2, RecordingStudioAI::Run.where(status: "completed").count
    assert_equal 2, @provider.refreshes.length
  end

  def test_batch_catalog_costs_are_omitted_after_cost_removal
    response = submit_two_items
    @provider.refresh_result = completed_result(with_cost: false)
    RecordingStudioAI.configuration.cost_catalogs = {
      test: { "batch-model" => { input_tokens: 1_000_000, output_tokens: 2_000_000, currency: "USD" } }
    }

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert refreshed.success?
    assert_nil refreshed.items.first.cost
    assert_nil refreshed.cost
  end

  def test_batch_mixed_currencies_leave_aggregate_cost_unknown
    response = submit_two_items
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "completed", provider_batch_id: "provider-batch-1",
      items: [
        completed_item("first", "one", input: 1, output: 1, cost: 100),
        completed_item("second", "two", input: 1, output: 1, cost: 200, currency: "EUR")
      ]
    )

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_nil refreshed.cost
  end

  def test_terminal_refresh_does_not_expose_later_unvalidated_provider_content
    schema = { type: "object", properties: { summary: { type: "string" } }, required: ["summary"] }
    submitted = RecordingStudioAI.submit_batch(
      items: [{ reference: "structured", prompt: "private", schema: schema }],
      provider: :test, root_recording: @root_recording, initiator: @initiator
    )
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "completed", provider_batch_id: "provider-batch-1",
      items: [RecordingStudioAI::Providers::BatchItemResult.new(
        reference: "structured", status: "completed", text: '{"summary":"valid"}'
      )]
    )
    RecordingStudioAI.refresh_batch(batch_id: submitted.batch.id, root_recording: @root_recording,
                                    initiator: @initiator)
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "completed", provider_batch_id: "provider-batch-1",
      items: [RecordingStudioAI::Providers::BatchItemResult.new(
        reference: "structured", status: "completed", text: '{"wrong":true}'
      )]
    )

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: submitted.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal "completed", refreshed.items.first.status
    assert_nil refreshed.items.first.text
    assert_nil refreshed.items.first.structured_data
  end

  def test_refresh_does_not_regress_processing_state
    response = submit_two_items
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "processing", provider_batch_id: "provider-batch-1",
      items: [RecordingStudioAI::Providers::BatchItemResult.new(reference: "first", status: "processing")]
    )
    RecordingStudioAI.refresh_batch(batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator)
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "submitted", provider_batch_id: "provider-batch-1",
      items: [RecordingStudioAI::Providers::BatchItemResult.new(reference: "first", status: "pending")]
    )

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal "processing", refreshed.status
    assert_equal "processing", refreshed.items.first.status
    assert_equal "running", refreshed.batch.batch_items.find_by!(reference: "first").run.status
  end

  def test_completed_provider_batch_terminalizes_missing_items_as_failed
    response = submit_two_items
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "completed",
      provider_batch_id: "provider-batch-1",
      items: [completed_item("first", "answer one", input: 4, output: 6, cost: 100)]
    )

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal "partially_completed", refreshed.status
    assert_equal %w[completed failed], refreshed.batch.batch_items.order(:position).pluck(:status)
    assert_equal %w[completed failed], RecordingStudioAI::Run.order(:id).pluck(:status)
    assert_empty RecordingStudioAI::BatchItem.where(status: %w[pending processing])
  end

  def test_structured_batch_output_is_validated_against_retained_normalized_schema
    schema = {
      type: "object",
      properties: { summary: { type: "string" } },
      required: ["summary"]
    }
    submitted = RecordingStudioAI.submit_batch(
      items: [{ reference: "structured", prompt: "private prompt", schema: schema }],
      provider: :test, root_recording: @root_recording, initiator: @initiator
    )
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "completed", provider_batch_id: "provider-batch-1",
      items: [RecordingStudioAI::Providers::BatchItemResult.new(
        reference: "structured", status: "completed", text: '{"wrong":true}'
      )]
    )

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: submitted.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal "partially_completed", refreshed.status
    assert_equal "failed", refreshed.items.first.status
    assert_equal "schema_validation", refreshed.items.first.error.category
    refute_includes submitted.batch.batch_items.first.metadata.to_json, "private prompt"
  end

  def test_batch_usage_remains_unknown_when_any_item_usage_is_unknown
    response = submit_two_items
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "completed", provider_batch_id: "provider-batch-1",
      items: [
        completed_item("first", "answer one", input: 4, output: 6, cost: 100),
        RecordingStudioAI::Providers::BatchItemResult.new(reference: "second", status: "completed", text: "answer two")
      ]
    )

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_nil refreshed.usage
    assert_nil refreshed.cost
  end

  def test_terminal_batch_item_and_run_statuses_cannot_be_reopened
    response = submit_two_items
    @provider.refresh_result = completed_result
    RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    refute response.batch.reload.update(status: "processing")
    refute response.batch.batch_items.first.update(status: "processing")
    refute response.batch.batch_items.first.run.update(status: "running")
  end

  def test_refresh_uses_persisted_provider_capabilities_after_profile_changes
    response = submit_two_items
    RecordingStudioAI.configuration.profiles[:medium] = []
    @provider.refresh_result = completed_result

    refreshed = RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert refreshed.success?
    assert_equal "completed", refreshed.status
  end

  def test_cancel_requires_explicit_cancellation_capability
    RecordingStudioAI.configuration.profiles[:medium].first[:capabilities] = %i[generation provider_batch]
    response = submit_two_items

    cancelled = RecordingStudioAI.cancel_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    refute cancelled.success?
    assert_equal "unsupported_capability", cancelled.error.category
    assert_empty @provider.cancellations
  end

  def test_cancel_calls_supported_provider_and_updates_status
    response = submit_two_items
    cancelled = RecordingStudioAI.cancel_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert cancelled.success?
    assert_equal "cancelled", cancelled.status
    assert_equal 1, @provider.cancellations.length
    assert_equal %w[cancelled cancelled], cancelled.batch.batch_items.order(:position).pluck(:status)
    assert_equal %w[cancelled cancelled], RecordingStudioAI::Run.order(:id).pluck(:status)
  end

  def test_batch_lookup_enforces_root_boundary
    response = submit_two_items

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.refresh_batch(
        batch_id: response.batch.id, root_recording: @other_root, initiator: @initiator
      )
    end
  end

  def test_submit_failure_is_normalized_and_terminalizes_all_records
    RecordingStudioAI.configuration.providers[:test] = ExplodingBatchProvider.new

    response = submit_two_items

    refute response.success?
    assert_equal "batch_submission", response.error.category
    assert_equal "failed", response.batch.status
    assert_equal %w[failed failed], response.batch.batch_items.order(:position).pluck(:status)
    assert_equal %w[failed failed], RecordingStudioAI::Run.order(:id).pluck(:status)
    refute_includes response.batch.attributes.values, "secret provider batch payload"
  end

  def test_batch_values_reject_sdk_objects_at_containment_boundary
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Providers::BatchItemResult.new(
        reference: "item", status: "completed", metadata: { sdk: Object.new }
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Providers::BatchResult.new(status: "failed")
    end
  end

  def test_openai_provider_uses_responses_jsonl_and_parses_output
    files = FakeOpenAIFiles.new
    client = Struct.new(:files, :batches).new(files, FakeOpenAIBatches.new)
    RecordingStudioAI.configuration.openai_client = client
    provider = RecordingStudioAI::Providers::OpenAI.new(configuration: RecordingStudioAI.configuration)
    candidate = RecordingStudioAI::Candidate.new(provider: :openai, model: "gpt-test",
                                                 capabilities: %i[generation provider_batch])
    request = normalized_request([{ reference: "ref-1", prompt: "private prompt" }])

    submitted = provider.submit_batch(request: request, candidate: candidate)
    refreshed = provider.refresh_batch(batch: Struct.new(:provider_batch_id).new("batch-1"), candidate: candidate)

    assert_equal "batch-1", submitted.provider_batch_id
    line = JSON.parse(files.uploaded.string.lines.first)
    assert_equal "/v1/responses", line.fetch("url")
    assert_equal "ref-1", line.fetch("custom_id")
    assert_equal false, line.dig("body", "store")
    assert_equal "completed", refreshed.items.first.status
    assert_equal "batch answer", refreshed.items.first.text
  end

  def test_openai_provider_normalizes_malformed_batch_jsonl
    files = FakeOpenAIFiles.new
    files.malformed = true
    client = Struct.new(:files, :batches).new(files, FakeOpenAIBatches.new)
    RecordingStudioAI.configuration.openai_client = client
    provider = RecordingStudioAI::Providers::OpenAI.new(configuration: RecordingStudioAI.configuration)
    candidate = RecordingStudioAI::Candidate.new(provider: :openai, model: "gpt-test",
                                                 capabilities: %i[generation provider_batch])

    result = provider.refresh_batch(batch: Struct.new(:provider_batch_id, :status).new("batch-1", "processing"),
                                    candidate: candidate)

    refute result.success?
    assert_equal "invalid_response", result.error.category
  end

  def test_openai_provider_cancels_and_normalizes_provider_batch
    batches = FakeOpenAIBatches.new
    client = Struct.new(:files, :batches).new(FakeOpenAIFiles.new, batches)
    RecordingStudioAI.configuration.openai_client = client
    provider = RecordingStudioAI::Providers::OpenAI.new(configuration: RecordingStudioAI.configuration)
    candidate = RecordingStudioAI::Candidate.new(
      provider: :openai,
      model: "gpt-test",
      capabilities: %i[generation provider_batch provider_batch_cancellation]
    )
    batch = Struct.new(:provider_batch_id, :status).new("batch-1", "processing")

    result = provider.cancel_batch(batch: batch, candidate: candidate)

    assert_equal "batch-1", batches.cancelled_id
    assert_equal "cancelled", result.status
    assert_equal "batch-1", result.provider_batch_id
  end

  def test_gemini_provider_uses_verified_keyed_batch_semantics
    client = FakeGeminiBatchClient.new
    RecordingStudioAI.configuration.gemini_client = client
    provider = RecordingStudioAI::Providers::Gemini.new(configuration: RecordingStudioAI.configuration)
    candidate = RecordingStudioAI::Candidate.new(provider: :gemini, model: "gemini-test",
                                                 capabilities: %i[generation provider_batch])

    submitted = provider.submit_batch(
      request: normalized_request([{ reference: "ref-1", prompt: "private prompt" }]), candidate: candidate
    )
    refreshed = provider.refresh_batch(batch: Struct.new(:provider_batch_id).new("batches/1"), candidate: candidate)

    assert_equal "ref-1", client.requests.first.fetch(:key)
    assert_equal "private prompt", client.requests.first.dig(:contents, 0, :parts, 0, :text)
    assert_equal "batches/1", submitted.provider_batch_id
    assert_equal "gemini answer", refreshed.items.first.text
  end

  def test_gemini_provider_cancels_and_normalizes_provider_batch
    client = FakeGeminiBatchClient.new
    RecordingStudioAI.configuration.gemini_client = client
    provider = RecordingStudioAI::Providers::Gemini.new(configuration: RecordingStudioAI.configuration)
    candidate = RecordingStudioAI::Candidate.new(
      provider: :gemini,
      model: "gemini-test",
      capabilities: %i[generation provider_batch provider_batch_cancellation]
    )
    batch = Struct.new(:provider_batch_id, :status).new("batches/1", "processing")

    result = provider.cancel_batch(batch: batch, candidate: candidate)

    assert_equal "batches/1", client.cancelled_name
    assert_equal "cancelled", result.status
    assert_equal "batches/1", result.provider_batch_id
  end

  private

  class FakeOpenAIFiles
    attr_reader :uploaded
    attr_accessor :malformed

    def create(file:, purpose:)
      @uploaded = file
      Struct.new(:id).new("file-1")
    end

    def content(_file_id)
      return StringIO.new("{not-json\n") if malformed

      StringIO.new(JSON.generate(
        custom_id: "ref-1",
        response: { status_code: 200, request_id: "req-1", body: {
          id: "resp-1", status: "completed", output_text: "batch answer",
          usage: { input_tokens: 2, output_tokens: 3, total_tokens: 5 }
        } }
      ) + "\n")
    end
  end

  class FakeOpenAIBatches
    attr_reader :cancelled_id

    def create(**) = { id: "batch-1", status: "validating" }
    def retrieve(*) = { id: "batch-1", status: "completed", output_file_id: "output-1" }

    def cancel(batch_id)
      @cancelled_id = batch_id
      { id: batch_id, status: "cancelled" }
    end
  end

  class FakeGeminiBatchClient
    attr_reader :requests, :cancelled_name

    def batch_generate_content(model:, requests:)
      @requests = requests
      { "name" => "batches/1", "metadata" => { "state" => "JOB_STATE_PENDING" } }
    end

    def get_batch(name)
      return { "name" => name, "metadata" => { "state" => "JOB_STATE_CANCELLED" } } if cancelled_name

      {
        "name" => name, "metadata" => { "state" => "JOB_STATE_SUCCEEDED" },
        "response" => { "dest" => { "inlinedResponses" => [{
          "metadata" => { "key" => "ref-1" },
          "response" => { "responseId" => "resp-1", "candidates" => [{
            "finishReason" => "STOP", "content" => { "parts" => [{ "text" => "gemini answer" }] }
          }] }
        }] } }
      }
    end

    def cancel_batch(name)
      @cancelled_name = name
      {}
    end
  end

  def test_nil_usage_handler_skips_the_resolver_and_still_submits
    resolver_calls = 0
    RecordingStudioAI.configuration.usage_key_resolver = lambda do |**|
      resolver_calls += 1
      raise "resolver must not run"
    end

    response = submit_two_items

    assert response.success?
    assert_equal 0, resolver_calls
    assert_equal 1, @provider.submissions.length
  end

  def test_nil_usage_key_skips_the_handler_and_still_submits
    handler_calls = 0
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) {}
    RecordingStudioAI.configuration.usage_handler = lambda do |**|
      handler_calls += 1
      raise "handler must not run"
    end

    response = submit_two_items

    assert response.success?
    assert_equal 0, handler_calls
    assert_equal 1, @provider.submissions.length
  end

  def test_submit_batch_spends_once_before_the_provider
    order = []
    spends = []
    assign_batch_meter(spends) { order << :handler }
    @provider.define_singleton_method(:submit_batch) do |request:, candidate:|
      order << :provider
      submissions << [request, candidate]
      submit_result
    end

    response = submit_two_items

    assert response.success?
    assert_equal %i[handler provider], order
    spend = spends.sole
    batch = response.batch
    assert_equal 2, spend.fetch(:quantity)
    assert_equal "ai-batch:#{batch.id}:submission", spend.fetch(:idempotency_key)
    assert_equal "batch", spend.dig(:metadata, :operation)
    assert_nil spend.dig(:metadata, :purpose)
    assert_equal [], spend.dig(:metadata, :provider_native_tools)
    assert_same @provider.submissions.sole.first.fetch(:attribution), spend.fetch(:attribution)
    refute_includes spend.fetch(:metadata).inspect, "sensitive first prompt"
    refute spend.fetch(:metadata).key?(:ai_run_id)
    refute spend.fetch(:metadata).key?(:attempt_id)
    refute spend.fetch(:metadata).key?(:attempt_kind)
  end

  def test_mixed_batch_spends_once_for_the_tool_union
    seen_tools = nil
    spends = []
    RecordingStudioAI.configuration.usage_key_resolver = lambda { |**kwargs|
      seen_tools = kwargs.fetch(:provider_native_tools)
      "ai.gemini_flash_search"
    }
    RecordingStudioAI.configuration.usage_handler = ->(**kwargs) { spends << kwargs }

    response = RecordingStudioAI.submit_batch(
      items: [
        { reference: "plain", prompt: "Summarize the notes." },
        { reference: "search", prompt: "What shipped this week?", provider_native_tools: [:web_search] }
      ],
      provider: :test, root_recording: @root_recording, initiator: @initiator
    )

    assert response.success?
    assert_equal 1, spends.length
    assert_equal 1, @provider.submissions.length
    assert_equal [:web_search], seen_tools
    assert seen_tools.frozen?
    assert_equal ["web_search"], spends.sole.dig(:metadata, :provider_native_tools)
    assert spends.sole.dig(:metadata, :provider_native_tools).frozen?
    assert_equal 2, spends.sole.fetch(:quantity)
    assert_equal "ai-batch:#{response.batch.id}:submission", spends.sole.fetch(:idempotency_key)
    assert_equal "batch", spends.sole.dig(:metadata, :operation)
    assert_nil spends.sole.dig(:metadata, :purpose)
    refute_includes spends.sole.fetch(:metadata).inspect, "What shipped this week?"
    refute_includes spends.sole.fetch(:metadata).inspect, "Summarize the notes."
  end

  def test_usage_refusal_on_submit_raises_and_does_not_call_the_provider
    refusal = RuntimeError.new("credits exhausted")
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.batch" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise refusal }

    error = assert_raises(RuntimeError) { submit_two_items }

    assert_same refusal, error
    assert_empty @provider.submissions
    batch = RecordingStudioAI::Batch.sole
    assert_equal "failed", batch.status
    assert_equal "usage", batch.error_category
    assert_equal "usage_declined", batch.error_code
    assert_equal "credits exhausted", batch.error_message
    assert_nil batch.submitted_at
    assert_nil batch.provider_batch_id
    assert batch.completed_at
    assert_equal batch.item_count, batch.failed_item_count
    assert_equal [0, 0], [batch.completed_item_count, batch.cancelled_item_count]
    batch.batch_items.each do |item|
      assert_equal "failed", item.status
      assert_equal "usage", item.error_category
      assert_equal "usage_declined", item.error_code
      assert_equal "credits exhausted", item.error_message
      assert item.completed_at
      assert_nil item.started_at
    end
    RecordingStudioAI::Run.find_each do |run|
      assert_equal "failed", run.status
      assert_equal "usage", run.error_category
      assert_equal "usage_declined", run.error_code
      assert_equal "credits exhausted", run.error_message
      assert run.completed_at
      assert_nil run.started_at
      assert_nil run.latency_ms
    end
    refute_equal "batch_submission_failed", batch.error_code
    refute_equal "batch_submission", batch.error_category
  end

  def test_long_batch_usage_refusal_message_is_truncated_to_255_characters
    message = "x" * 300
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.batch" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise message }

    error = assert_raises(RuntimeError) { submit_two_items }

    assert_equal message, error.message
    assert_equal message[0, 255], RecordingStudioAI::Batch.sole.error_message
    assert_equal [message[0, 255]], RecordingStudioAI::BatchItem.distinct.pluck(:error_message)
    assert_equal [message[0, 255]], RecordingStudioAI::Run.distinct.pluck(:error_message)
  end

  def test_spend_batch_submission_twice_reuses_the_idempotency_key
    response = submit_two_items
    batch = response.batch
    spends = []
    seen_tools = []
    RecordingStudioAI.configuration.usage_key_resolver = lambda { |**kwargs|
      seen_tools << kwargs.fetch(:provider_native_tools)
      "ai.batch"
    }
    RecordingStudioAI.configuration.usage_handler = ->(**kwargs) { spends << kwargs }

    2.times do
      assert_nil RecordingStudioAI::Usage.spend_batch_submission!(
        batch: batch,
        attribution: batch_attribution,
        provider_native_tools: [:web_search, "web_search"]
      )
    end

    keys = spends.map { |spend| spend.fetch(:idempotency_key) }
    names = spends.map { |spend| spend.dig(:metadata, :provider_native_tools) }
    assert_equal ["ai-batch:#{batch.id}:submission", "ai-batch:#{batch.id}:submission"], keys
    assert_equal [[:web_search], [:web_search]], seen_tools
    assert_equal [["web_search"], ["web_search"]], names
  end

  def test_a_second_submit_batch_creates_a_different_usage_key
    spends = []
    assign_batch_meter(spends)

    first = submit_two_items
    second = submit_two_items

    keys = spends.map { |spend| spend.fetch(:idempotency_key) }
    assert_equal [
      "ai-batch:#{first.batch.id}:submission",
      "ai-batch:#{second.batch.id}:submission"
    ], keys
    assert_equal 2, keys.uniq.length
  end

  def test_provider_error_after_a_successful_batch_spend_returns_a_response
    spends = []
    assign_batch_meter(spends)
    RecordingStudioAI.configuration.providers[:test] = ExplodingBatchProvider.new

    response = submit_two_items

    assert_instance_of RecordingStudioAI::Contracts::BatchResponse, response
    refute response.success?
    assert_equal "batch_submission", response.error.category
    assert_equal "batch_submission_failed", response.error.code
    assert_equal 1, spends.length
    assert_equal "batch_submission_failed", response.batch.error_code
    assert_equal "batch_submission", response.batch.error_category
  end

  def test_refresh_and_cancel_do_not_call_the_usage_handler
    spends = []
    assign_batch_meter(spends)
    response = submit_two_items

    RecordingStudioAI.refresh_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )
    RecordingStudioAI.cancel_batch(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal 1, spends.length
    assert_equal 1, @provider.refreshes.length
    assert_equal 1, @provider.cancellations.length

    scheduled = nil
    polling_job = Class.new do
      define_singleton_method(:perform_later) { |**arguments| scheduled = arguments }
    end
    RecordingStudioAI.configuration.batch_synchronization_job = polling_job
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "usage handler must not run" }
    RecordingStudioAI.refresh_batch_async(
      batch_id: response.batch.id, root_recording: @root_recording, initiator: @initiator
    )

    assert_equal response.batch.id, scheduled.fetch(:batch_id)
  end

  def test_batch_spend_reads_the_global_configuration
    calls = []
    local = RecordingStudioAI::Configuration.new
    local.attribution_validator = ->(**) {}
    local.authorization_handler = ->(**) { true }
    local.providers[:test] = @provider
    local.allowed_provider_overrides = [:test]
    local.profiles[:medium] = [{
      provider: :test, model: "batch-model",
      capabilities: %i[generation provider_native_web_search provider_batch provider_batch_cancellation]
    }]
    local.usage_handler = nil
    local.usage_key_resolver = ->(**) { raise "local resolver must not run" }
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.batch" }
    RecordingStudioAI.configuration.usage_handler = ->(**kwargs) { calls << kwargs }
    request = normalized_request([{ reference: "only", prompt: "one" }])

    response = RecordingStudioAI::BatchOrchestrator.new(configuration: local).submit(request)

    assert response.success?
    assert_equal 1, calls.length
    assert_equal 1, @provider.submissions.length
    assert_equal "ai-batch:#{response.batch.id}:submission", calls.sole.fetch(:idempotency_key)
  end

  def submit_two_items
    RecordingStudioAI.submit_batch(
      items: [{ reference: "first", prompt: "sensitive first prompt" },
              { reference: "second", prompt: "sensitive second prompt" }],
      provider: :test, root_recording: @root_recording, initiator: @initiator
    )
  end

  def completed_result(with_cost: true)
    RecordingStudioAI::Providers::BatchResult.new(
      status: "completed", provider_batch_id: "provider-batch-1",
      items: [
        completed_item("first", "answer one", input: 4, output: 6, cost: with_cost ? 100 : nil),
        completed_item("second", "answer two", input: 2, output: 3, cost: with_cost ? 200 : nil)
      ]
    )
  end

  def completed_item(reference, text, input:, output:, cost:, currency: "USD")
    RecordingStudioAI::Providers::BatchItemResult.new(
      reference: reference, status: "completed", text: text, finish_reason: "stop",
      usage: RecordingStudioAI::Contracts::Usage.new(
        input_tokens: input, output_tokens: output, total_tokens: input + output
      ),
      cost: cost && RecordingStudioAI::Contracts::Cost.new(
        amount: cost, currency: currency, estimated: false, source: "provider"
      )
    )
  end

  def normalized_request(items)
    RecordingStudioAI::Contracts::RequestValidation.validate_batch_submit_request!(
      items: items, root_recording: @root_recording, initiator: @initiator
    )
  end

  def assign_batch_meter(bucket)
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.batch" }
    RecordingStudioAI.configuration.usage_handler = lambda do |**kwargs|
      yield if block_given?
      bucket << kwargs
    end
  end

  def batch_attribution
    RecordingStudioAI::Contracts::Attribution.new(root_recording: @root_recording, initiator: @initiator)
  end

  def configured_configuration
    RecordingStudioAI::Configuration.new.tap do |configuration|
      configuration.attribution_validator = ->(**) {}
      configuration.authorization_handler = ->(**) { true }
      configuration.providers[:test] = @provider
      configuration.allowed_provider_overrides = [:test]
      configuration.profiles[:medium] = [{
        provider: :test, model: "batch-model",
        capabilities: %i[generation structured_output image_input file_input provider_native_web_search provider_batch provider_batch_cancellation]
      }]
    end
  end
end
