# frozen_string_literal: true

require "test_helper"
require "active_record"

migration_file = Dir[File.expand_path("../db/migrate/*_create_recording_studio_ai_persistence_tables.rb",
                                      __dir__)].first
require migration_file
require_relative "../db/migrate/20260814120000_add_prompt_attribution_to_recording_studio_ai_runs"
require_relative "../db/migrate/20260812150000_remove_correlation_ids_from_recording_studio_ai"

require_relative "../app/models/recording_studio_ai/application_record"
require_relative "../app/models/concerns/recording_studio_ai/terminal_immutability"
require_relative "../app/models/recording_studio_ai/run"
require_relative "../app/models/recording_studio_ai/attempt"
require_relative "../app/models/recording_studio_ai/custom_tool_invocation"
require_relative "../app/models/recording_studio_ai/batch"
require_relative "../app/models/recording_studio_ai/batch_item"
require_relative "../app/models/recording_studio_ai/response"
require_relative "../app/jobs/recording_studio_ai/response_cleanup_job"

class PhaseTwelveResponseRetentionObservabilityTest < Minitest::Test
  Actor = Struct.new(:id)

  class Provider < RecordingStudioAI::Providers::Base
    def generate(request:, candidate:)
      RecordingStudioAI::Providers::Result.new(
        text: "assembled response",
        provider_request_id: "provider-response-1",
        finish_reason: "stop"
      )
    end
  end

  class ErrorProvider < RecordingStudioAI::Providers::Base
    def generate(request:, candidate:)
      RecordingStudioAI::Providers::Result.new(
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: "provider_error", code: "provider_failed", message: "Safe provider failure",
          retryable: false, provider: candidate.provider
        )
      )
    end
  end

  class StreamProvider < RecordingStudioAI::Providers::Base
    def stream(request:, candidate:)
      yield RecordingStudioAI::Providers::StreamEvent.new(type: :text_delta, text_delta: "private-chunk-one")
      yield RecordingStudioAI::Providers::StreamEvent.new(type: :text_delta, text_delta: "private-chunk-two")
      RecordingStudioAI::Providers::Result.new(text: "assembled stream", provider_request_id: "stream-1")
    end
  end

  def setup
    ActiveRecord::Encryption.configure(
      primary_key: "phase-twelve-primary-key",
      deterministic_key: "phase-twelve-deterministic-key",
      key_derivation_salt: "phase-twelve-key-derivation-salt"
    )
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.connection.create_table(:recording_studio_recordings) { |table| table.timestamps }
    ActiveRecord::Migration.suppress_messages do
      CreateRecordingStudioAIPersistenceTables.migrate(:up)
      AddPromptAttributionToRecordingStudioAIRuns.migrate(:up)
      RemoveCorrelationIdsFromRecordingStudioAI.migrate(:up)
    end
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(71)
    @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    RecordingStudioAI.instance_variable_set(:@configuration, configured_configuration)
    install_recording_lookup_double
  end

  def teardown
    RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
    RecordingStudio.send(:remove_const, :Recording) if @remove_recording_lookup_double
  end

  def test_enabled_retention_stores_assembled_generation_response_with_expiry
    response = RecordingStudioAI.generate(
      prompt: "private prompt",
      root_recording: @root_recording,
      initiator: @initiator,
      provider: :test
    )

    assert response.success?
    retained = RecordingStudioAI::Response.first
    refute_nil retained
    assert_equal RecordingStudioAI::Attempt.first, retained.attempt
    assert_equal "generation", retained.response_type
    assert_equal "assembled response", retained.content_text
    assert_equal "provider-response-1", retained.provider_response_id
    assert_in_delta 7.days.from_now, retained.expires_at, 2.seconds
    refute_includes retained.attributes.values, "private prompt"
  end

  def test_retention_defaults_off_and_database_contains_ciphertext
    RecordingStudioAI.configuration.retain_responses = false
    generate
    assert_equal 0, RecordingStudioAI::Response.count

    RecordingStudioAI.configuration.retain_responses = true
    generate
    retained = RecordingStudioAI::Response.first
    retained.update!(
      raw_response: JSON.generate(id: "assembled response"),
      normalized_response: JSON.generate(text: "assembled response"),
      content_text: "assembled response"
    )
    stored = ActiveRecord::Base.connection.select_one(
      "SELECT raw_response, normalized_response, content_text " \
      "FROM recording_studio_ai_responses WHERE id = #{retained.id}"
    )

    %w[raw_response normalized_response content_text].each do |field|
      refute_equal retained.public_send(field), stored.fetch(field)
      refute_includes stored.fetch(field), "assembled response"
    end
  end

  def test_retained_responses_delete_without_deleting_execution_history
    generate
    attempt_response = RecordingStudioAI::Response.first
    attempt = attempt_response.attempt
    run = attempt.run
    item = create_batch_item
    batch_response = item.create_response!(response_type: "batch_item", expires_at: 1.day.from_now)
    batch = item.batch
    batch_run = item.run

    attempt_response.destroy!
    batch_response.destroy!

    assert RecordingStudioAI::Run.exists?(run.id)
    assert RecordingStudioAI::Attempt.exists?(attempt.id)
    assert RecordingStudioAI::Batch.exists?(batch.id)
    assert RecordingStudioAI::BatchItem.exists?(item.id)
    assert RecordingStudioAI::Run.exists?(batch_run.id)
  end

  def test_recursive_and_host_sanitizers_redact_nested_secrets_and_signed_urls
    RecordingStudioAI.configuration.response_sanitizer = lambda do |value|
      value.merge("host_value" => "sanitized")
    end
    value = {
      authorization: "Bearer secret", nested: [{ api_key: "key", safe: "yes" }],
      url: "https://example.test/file?X-Amz-Signature=signed&name=report"
    }

    sanitized = RecordingStudioAI::Retention.sanitize(value)

    assert_equal "[REDACTED]", sanitized["authorization"]
    assert_equal "[REDACTED]", sanitized.dig("nested", 0, "api_key")
    assert_equal "yes", sanitized.dig("nested", 0, "safe")
    refute_includes sanitized["url"], "signed"
    assert_includes sanitized["url"], "name=report"
    assert_equal "sanitized", sanitized["host_value"]
    metrics = RecordingStudioAI::Retention.sanitize({ input_tokens: 3, output_tokens: 2, access_token: "secret" })
    assert_equal 3, metrics["input_tokens"]
    assert_equal 2, metrics["output_tokens"]
    assert_equal "[REDACTED]", metrics["access_token"]
  end

  def test_raw_snapshot_is_serializable_allowlisted_and_sanitized
    result = RecordingStudioAI::Providers::Result.new(
      text: "response",
      retention_snapshot: {
        id: "raw-1", status: "completed", authorization_header: "Bearer secret",
        usage: { api_key: "secret", total_tokens: 4 }, provider_payload: "not allowlisted"
      }
    )
    run = create_run
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed", provider: "test",
                                   model: "snapshot", started_at: Time.current, completed_at: Time.current)

    RecordingStudioAI::Retention.retain_attempt!(attempt, result)
    raw = JSON.parse(attempt.response.raw_response)

    assert_equal "raw-1", raw["id"]
    assert_equal "[REDACTED]", raw.dig("usage", "api_key")
    refute raw.key?("authorization_header")
    refute raw.key?("provider_payload")
  end

  def test_sanitizer_exception_never_corrupts_finalized_attempt
    RecordingStudioAI.configuration.response_sanitizer = ->(*) { raise "sensitive callback failure" }

    response = generate

    assert response.success?
    assert_equal "completed", RecordingStudioAI::Attempt.first.status
    retained = RecordingStudioAI::Response.first
    assert_equal({}, JSON.parse(retained.normalized_response))
    assert_nil retained.content_text
    assert_equal({}, retained.metadata)
  end

  def test_bounded_retention_is_valid_utf8_and_json
    RecordingStudioAI.configuration.maximum_retained_response_size = 96
    result = RecordingStudioAI::Providers::Result.new(text: "é" * 200, metadata: { note: "x" * 200 })
    run = create_run
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed", provider: "test",
                                   model: "bounded", started_at: Time.current, completed_at: Time.current)

    RecordingStudioAI::Retention.retain_attempt!(attempt, result)
    retained = attempt.response

    assert retained.truncated
    assert_operator retained.byte_size, :<=, 96
    assert retained.content_text.valid_encoding?
    assert retained.normalized_response.valid_encoding?
    assert_instance_of Hash, JSON.parse(retained.normalized_response)
    assert_equal retained.byte_size,
                 [retained.raw_response, retained.normalized_response, retained.content_text].compact.sum(&:bytesize)
  end

  def test_zero_byte_retention_limit_keeps_only_response_metadata
    RecordingStudioAI.configuration.maximum_retained_response_size = 0

    generate
    retained = RecordingStudioAI::Response.first

    assert retained.truncated
    assert_equal 0, retained.byte_size
    assert_nil retained.raw_response
    assert_nil retained.normalized_response
    assert_nil retained.content_text
  end

  def test_truncated_structured_content_is_omitted_instead_of_becoming_invalid_json
    RecordingStudioAI.configuration.maximum_retained_response_size = 80
    result = RecordingStudioAI::Providers::Result.new(
      text: JSON.generate(summary: "é" * 200),
      structured_data: { "summary" => "é" * 200 }
    )
    run = create_run
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "completed", provider: "test",
                                   model: "structured", started_at: Time.current, completed_at: Time.current)

    RecordingStudioAI::Retention.retain_attempt!(attempt, result)
    retained = attempt.response

    assert retained.truncated
    assert_equal "application/json", retained.content_type
    assert_nil retained.content_text
    assert_instance_of Hash, JSON.parse(retained.normalized_response)
  end

  def test_failed_retention_is_incomplete_and_omits_provider_metadata
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "provider_error", code: "failed", message: "Safe failure", provider: "test"
    )
    result = RecordingStudioAI::Providers::Result.new(
      error: error,
      metadata: { prompt: "private prompt", messages: ["private message"], tool_arguments: { secret: "value" } }
    )
    run = create_run
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "failed", provider: "test",
                                   model: "error", started_at: Time.current, completed_at: Time.current)

    RecordingStudioAI::Retention.retain_attempt!(attempt, result)
    retained = attempt.response
    normalized = JSON.parse(retained.normalized_response)

    refute retained.complete
    refute normalized.key?("metadata")
    refute_includes retained.normalized_response, "private prompt"
    refute_includes retained.normalized_response, "private message"
  end

  def test_stream_retains_only_provider_assembled_result
    RecordingStudioAI.configuration.providers[:test] = StreamProvider.new
    RecordingStudioAI.configuration.profiles[:medium].first[:capabilities] << :streaming
    events = []

    RecordingStudioAI.stream(
      prompt: "private prompt", root_recording: @root_recording, initiator: @initiator, provider: :test
    ) { |event| events << event }

    retained = RecordingStudioAI::Response.first
    assert_equal "stream", retained.response_type
    assert_equal "assembled stream", retained.content_text
    refute_includes retained.normalized_response, "private-chunk-one"
    assert_equal(2, events.count { |event| event.type == "text_delta" })
  end

  def test_normalized_error_and_batch_item_retention_are_idempotent
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "provider_error", code: "safe_code", message: "Safe failure", provider: "test"
    )
    run = create_run
    attempt = run.attempts.create!(sequence: 1, kind: "primary", status: "failed", provider: "test",
                                   model: "error-model", started_at: Time.current, completed_at: Time.current)
    RecordingStudioAI::Retention.retain_attempt!(attempt, RecordingStudioAI::Providers::Result.new(error: error))
    assert_equal "safe_code", JSON.parse(attempt.response.normalized_response).dig("error", "code")

    batch_item = create_batch_item
    item_result = RecordingStudioAI::Providers::BatchItemResult.new(
      reference: batch_item.reference, provider_item_id: "provider-item-1", status: "completed", text: "batch output"
    )
    2.times { RecordingStudioAI::Retention.retain_batch_item!(batch_item, item_result) }

    assert_equal 1, RecordingStudioAI::Response.where(batch_item_id: batch_item.id).count
    assert_equal "batch output", batch_item.response.content_text
    assert_equal "batch_item", batch_item.response.response_type
  end

  def test_reader_authorizes_with_root_derived_from_owner_run
    generate
    retained = RecordingStudioAI::Response.first
    calls = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << [action, attribution, context]
      false
    end

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.read_retained_response(response: retained, initiator: @initiator)
    end
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, attribution:, context:|
      calls << [action, attribution, context]
      true
    end

    content = RecordingStudioAI.read_retained_response(response: retained, initiator: @initiator)

    assert_equal "assembled response", content[:content_text]
    assert_equal "recording_studio_ai.view_retained_response", calls.last.first
    assert_equal @root_recording.id, calls.last[1].root_recording.id
    assert_equal retained.attempt.run_id, calls.last[2]["run_id"] || calls.last[2][:run_id]
  end

  def test_reader_rejects_expired_response_without_mutating_it
    generate
    retained = RecordingStudioAI::Response.first
    retained.update_column(:expires_at, 1.minute.ago)

    assert_raises(ActiveRecord::RecordNotFound) do
      RecordingStudioAI.read_retained_response(response: retained, initiator: @initiator)
    end
    assert RecordingStudioAI::Response.exists?(retained.id)
  end

  def test_expired_scope_cleanup_service_and_job
    generate
    expired = RecordingStudioAI::Response.first
    expired.update_column(:expires_at, 1.minute.ago)
    generate
    active = RecordingStudioAI::Response.order(:id).last

    assert_equal [expired], RecordingStudioAI::Response.expired.to_a
    assert_equal 1, RecordingStudioAI::ResponseCleanupJob.perform_now
    assert_equal [active], RecordingStudioAI::Response.all.to_a
  end

  def test_history_cleanup_is_opt_in_and_preserves_newer_canonical_records
    old_run = create_run
    old_run.update_columns(created_at: 31.days.ago, completed_at: 31.days.ago)
    old_attempt = old_run.attempts.create!(sequence: 1, kind: "primary", status: "completed")
    old_attempt.create_response!(response_type: "generation", expires_at: 1.day.from_now)
    current_run = create_run
    recently_completed_run = create_run
    recently_completed_run.update_column(:created_at, 31.days.ago)
    blocked_run = create_run
    blocked_run.update_columns(created_at: 31.days.ago, completed_at: 31.days.ago)
    blocked_run.attempts.create!(sequence: 1, kind: "primary", status: "running")

    disabled = RecordingStudioAI::HistoryCleanup.call(now: Time.current)
    assert_equal 0, disabled.runs
    assert RecordingStudioAI::Run.exists?(old_run.id)

    RecordingStudioAI.configuration.execution_history_retention_period = 30.days
    result = RecordingStudioAI::HistoryCleanup.call(now: Time.current)

    assert_equal 1, result.responses
    assert_equal 1, result.attempts
    assert_equal 1, result.runs
    refute RecordingStudioAI::Run.exists?(old_run.id)
    assert RecordingStudioAI::Run.exists?(current_run.id)
    assert RecordingStudioAI::Run.exists?(recently_completed_run.id)
    assert RecordingStudioAI::Run.exists?(blocked_run.id)
  end

  def test_notifications_have_stable_names_and_content_free_payloads
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Arecording_studio_ai\./) do |*arguments|
      event = ActiveSupport::Notifications::Event.new(*arguments)
      events << [event.name, event.payload]
    end

    generate
    run = create_run
    run.attempts.create!(sequence: 1, kind: "retry", status: "running", provider: "test", model: "retry")
    run.attempts.create!(sequence: 2, kind: "fallback", status: "running", provider: "test", model: "fallback",
                         streaming: true)
    run.custom_tool_invocations.create!(
      tool_key: "safe_tool", tool_version: 1, status: "requested", read_only: true, destructive: false,
      requires_confirmation: false, idempotent: true, metadata: {}
    )
    create_batch_item
    processing_batch = RecordingStudioAI::Batch.create!(
      status: "processing", root_recording_id: @root_recording.id,
      initiator_type: @initiator.class.name, initiator_id: @initiator.id, initiator_kind: "user", metadata: {}
    )
    processing_batch.update!(metadata: { refreshed: true })

    names = events.map(&:first)
    assert_includes names, "recording_studio_ai.attempt.completed"
    assert_includes names, "recording_studio_ai.run.completed"
    assert_includes names, "recording_studio_ai.retry.scheduled"
    assert_includes names, "recording_studio_ai.fallback.selected"
    assert_includes names, "recording_studio_ai.stream.started"
    assert_includes names, "recording_studio_ai.custom_tool.requested"
    assert_includes names, "recording_studio_ai.batch.completed"
    assert_includes names, "recording_studio_ai.batch.updated"
    assert_includes names, "recording_studio_ai.batch_item.completed"
    serialized = JSON.generate(events)
    refute_includes serialized, "private prompt"
    refute_includes serialized, "assembled response"
    assert(events.all? do |_name, payload|
      (payload.keys & %i[prompt output chunks attachments tool_args result]).empty?
    end)

    completed_attempt = RecordingStudioAI::Attempt.where(status: "completed").first
    event_count = events.count { |name, _payload| name == "recording_studio_ai.attempt.completed" }
    completed_attempt.update!(metadata: { safe: true })
    assert_equal(event_count, events.count { |name, _payload| name == "recording_studio_ai.attempt.completed" })

    unsafe = create_run
    unsafe.attempts.create!(
      sequence: 1, kind: "primary", status: "failed", provider: "test", model: "safe-model",
      error_code: "private payload with spaces", finish_reason: "private\ncontent"
    )
    unsafe_payload = events.last.fetch(1)
    refute unsafe_payload.key?(:error_code)
    refute unsafe_payload.key?(:finish_reason)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_warning_metrics_are_deterministic_and_report_threshold_breaches
    generate
    RecordingStudioAI.configuration.providers[:test] = ErrorProvider.new
    generate
    thresholds = RecordingStudioAI.configuration.admin_warning_thresholds.merge(
      error_rate: 0.5, total_tokens: 1, provider_error_rate: 0.5
    )

    report = RecordingStudioAI::WarningMetrics.new(since: 1.hour.ago, thresholds: thresholds).call

    assert_equal 0.5, report[:values][:error_rate]
    assert_equal 0.5, report[:values][:provider_error_rate]
    assert_includes report[:breaches].map { |breach| breach[:metric] }, :error_rate
    assert_includes report[:breaches].map { |breach| breach[:metric] }, :provider_error_rate
    assert_equal %i[runs error_rate input_tokens output_tokens total_tokens average_latency_ms
                    slow_calls retries fallbacks tool_calls maximum_tool_calls_per_run expensive_model_runs destructive_requests
                    confirmation_rejections batch_failures batch_expirations provider_error_rate],
                 report[:values].keys
  end

  def test_warning_metrics_count_individual_slow_calls
    fast = create_run
    fast.update_columns(latency_ms: 10, created_at: Time.current)
    slow = create_run
    slow.update_columns(latency_ms: 20_000, created_at: Time.current)
    RecordingStudioAI.configuration.admin_slow_call_threshold_ms = 10_000

    report = RecordingStudioAI::WarningMetrics.new(since: 1.hour.ago, thresholds: { slow_calls: 1 }).call

    assert_equal 1, report[:values][:slow_calls]
    assert_includes report[:breaches].map { |breach| breach[:metric] }, :slow_calls
  end

  def test_warning_failure_rates_ignore_active_executions
    failed_run = create_run(status: "failed")
    failed_run.attempts.create!(sequence: 1, kind: "primary", status: "failed", provider: "openai")
    active_run = create_run(status: "running")
    active_run.attempts.create!(sequence: 1, kind: "primary", status: "running", provider: "openai")

    values = RecordingStudioAI::WarningMetrics.new(since: 1.hour.ago).call.fetch(:values)

    assert_equal 1.0, values.fetch(:error_rate)
    assert_equal 1.0, values.fetch(:provider_error_rate)
  end

  def test_warning_metrics_preserve_unknown_values_for_empty_windows
    report = RecordingStudioAI::WarningMetrics.new(since: 1.minute.from_now).call

    assert_nil report[:values][:error_rate]
    assert_nil report[:values][:total_tokens]
    assert_nil report[:values][:spend_microunits]
    assert_nil report[:values][:average_latency_ms]
    assert_nil report[:values][:provider_error_rate]
    assert_empty report[:breaches]
  end

  def test_concrete_provider_results_include_allowlisted_retention_snapshots
    openai = RecordingStudioAI::Providers::OpenAI.new(configuration: RecordingStudioAI.configuration)
    gemini = RecordingStudioAI::Providers::Gemini.new(configuration: RecordingStudioAI.configuration)
    openai_response = {
      id: "resp-1", model: "gpt-test", status: "completed", output_text: "answer",
      usage: { input_tokens: 2, output_tokens: 1, total_tokens: 3 }
    }
    gemini_response = {
      "responseId" => "gem-1",
      "modelVersion" => "gemini-test",
      "candidates" => [{ "finishReason" => "STOP", "content" => { "parts" => [{ "text" => "answer" }] } }],
      "usageMetadata" => { "promptTokenCount" => 2, "candidatesTokenCount" => 1, "totalTokenCount" => 3 }
    }
    RecordingStudioAI.configuration.openai_client = Struct.new(:responses).new(
      Struct.new(:response) { def create(**) = response }.new(openai_response)
    )
    RecordingStudioAI.configuration.gemini_client = Struct.new(:models).new(
      Struct.new(:response) { def generate_content(**) = response }.new(gemini_response)
    )
    candidate = ->(provider) { RecordingStudioAI::Candidate.new(provider: provider, model: "test", capabilities: [:generation]) }
    request = { prompt: "private", messages: nil, system_instruction: nil, attachments: [],
                provider_native_tools: [], custom_tools: [], schema: nil }

    openai_result = openai.generate(request: request, candidate: candidate.call(:openai))
    gemini_result = gemini.generate(request: request, candidate: candidate.call(:gemini))

    assert_equal "resp-1", openai_result.retention_snapshot[:id] || openai_result.retention_snapshot["id"]
    openai_usage = openai_result.retention_snapshot[:usage] || openai_result.retention_snapshot["usage"]
    assert_equal 3, openai_usage[:total_tokens] || openai_usage["total_tokens"]
    assert_equal "gem-1", gemini_result.retention_snapshot[:id] || gemini_result.retention_snapshot["id"]
    gemini_usage = gemini_result.retention_snapshot[:usage] || gemini_result.retention_snapshot["usage"]
    assert_equal 3, gemini_usage[:total_tokens] || gemini_usage["total_tokens"]
  end

  private

  def install_recording_lookup_double
    return if RecordingStudio.const_defined?(:Recording, false)

    actor_class = Actor
    RecordingStudio.const_set(:Recording, Class.new do
      define_singleton_method(:find) { |id| actor_class.new(id) }
    end)
    @remove_recording_lookup_double = true
  end

  def configured_configuration
    RecordingStudioAI::Configuration.new.tap do |configuration|
      configuration.attribution_validator = ->(**) {}
      configuration.authorization_handler = ->(**) { true }
      configuration.retain_responses = true
      configuration.providers[:test] = Provider.new
      configuration.allowed_provider_overrides = [:test]
      configuration.profiles[:medium] = [{ provider: :test, model: "test-model", capabilities: [:generation] }]
    end
  end

  def generate
    RecordingStudioAI.generate(
      prompt: "private prompt", root_recording: @root_recording, initiator: @initiator, provider: :test
    )
  end

  def create_run(status: "completed")
    RecordingStudioAI::Run.create!(
      operation: "generation", status: status,
      root_recording_id: @root_recording.id, initiator_type: @initiator.class.name,
      initiator_id: @initiator.id, initiator_kind: "user", started_at: Time.current,
      completed_at: RecordingStudioAI::Run.terminal_statuses.include?(status) ? Time.current : nil,
      metadata: {}
    )
  end

  def create_batch_item
    run = create_run
    batch = RecordingStudioAI::Batch.create!(
      status: "completed", provider: "test", model: "batch-model",
      root_recording_id: @root_recording.id, initiator_type: @initiator.class.name,
      initiator_id: @initiator.id, initiator_kind: "user", item_count: 1, completed_item_count: 1,
      metadata: {}
    )
    batch.batch_items.create!(run: run, position: 0, reference: "item-1", status: "completed", metadata: {})
  end

  def create_recording_id
    ActiveRecord::Base.connection.insert(
      "INSERT INTO recording_studio_recordings (created_at, updated_at) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
  end
end
