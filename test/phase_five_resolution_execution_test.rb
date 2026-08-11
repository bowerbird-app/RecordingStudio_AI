# frozen_string_literal: true

require "test_helper"
require "active_record"

migration_file = Dir[File.expand_path("../db/migrate/*_create_recording_studio_ai_persistence_tables.rb",
                                      __dir__)].first
require migration_file

require_relative "../app/models/recording_studio_ai/application_record"
require_relative "../app/models/concerns/recording_studio_ai/terminal_immutability"
require_relative "../app/models/recording_studio_ai/run"
require_relative "../app/models/recording_studio_ai/attempt"

class PhaseFiveResolutionExecutionTest < Minitest::Test
  Actor = Struct.new(:id)

  class TestAdapter < RecordingStudioAI::Adapters::Base
    attr_reader :requests

    def initialize(result: nil)
      @result = result || RecordingStudioAI::Adapters::Result.new(text: "Generated", finish_reason: "stop")
      @requests = []
    end

    def generate(request:, candidate:)
      requests << { request: request, candidate: candidate }
      @result
    end
  end

  class FailingAdapter < RecordingStudioAI::Adapters::Base
    def generate(request:, candidate:)
      raise "secret provider payload"
    end
  end

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    bootstrap_external_recording_studio_table
    ActiveRecord::Migration.suppress_messages do
      CreateRecordingStudioAIPersistenceTables.migrate(:up)
    end

    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(17)
    @adapter = TestAdapter.new
    @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    RecordingStudioAI.instance_variable_set(:@configuration, configured_configuration)
  end

  def teardown
    RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end

  def test_resolver_uses_profile_order_and_requires_every_capability
    configuration = RecordingStudioAI.configuration
    configuration.profiles[:medium] = [
      { provider: :test, model: "text-only", capabilities: %i[generation] },
      { provider: :test, model: "structured", capabilities: %i[generation structured_output] }
    ]

    candidate = RecordingStudioAI::Resolver.new(configuration: configuration).resolve(
      profile: :medium,
      required_capabilities: %i[generation structured_output]
    )

    assert_equal "structured", candidate.model
    assert_equal %i[generation structured_output], candidate.capabilities
  end

  def test_generate_uses_the_configured_default_profile
    RecordingStudioAI.configuration.default_profile = :low
    RecordingStudioAI.configuration.profiles[:low] = [
      { provider: :test, model: "economy", capabilities: %i[generation] }
    ]

    response = RecordingStudioAI.generate(
      prompt: "Summarize",
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert response.success?
    assert_equal :low, response.profile
    assert_equal "economy", response.model
  end

  def test_unsupported_capability_creates_no_run_or_attempt_and_never_calls_adapter
    response = RecordingStudioAI.generate(
      prompt: "Summarize",
      schema: { type: "object" },
      root_recording: @root_recording,
      initiator: @initiator
    )

    refute response.success?
    assert_equal "unsupported_capability", response.error.category
    assert_equal 0, RecordingStudioAI::Run.count
    assert_equal 0, RecordingStudioAI::Attempt.count
    assert_empty @adapter.requests
  end

  def test_provider_override_must_be_explicitly_allowed
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Summarize",
        provider: :other,
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "configuration", error.code
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty @adapter.requests
  end

  def test_candidate_without_an_adapter_creates_no_execution_records
    RecordingStudioAI.configuration.profiles[:medium] = [
      { provider: :missing, model: "unavailable", capabilities: %i[generation] }
    ]

    response = RecordingStudioAI.generate(
      prompt: "Summarize",
      root_recording: @root_recording,
      initiator: @initiator
    )

    refute response.success?
    assert_equal "configuration", response.error.category
    assert_equal 0, RecordingStudioAI::Run.count
    assert_equal 0, RecordingStudioAI::Attempt.count
  end

  def test_generate_dispatches_through_adapter_and_persists_safe_execution_records
    response = RecordingStudioAI.generate(
      prompt: "Sensitive prompt that must not persist",
      purpose: "summarize_page",
      provider: :test,
      root_recording: @root_recording,
      initiator: @initiator,
      execution_source: :job,
      metadata: { feature: "pages" }
    )

    assert response.success?
    assert_equal "Generated", response.text
    assert_equal "test", response.provider
    assert_equal "balanced", response.model
    assert_equal 1, @adapter.requests.length

    run = RecordingStudioAI::Run.first
    attempt = RecordingStudioAI::Attempt.first
    assert_equal "completed", run.status
    assert_equal "test", run.requested_provider
    assert_equal "test", run.resolved_provider
    assert_equal "balanced", run.resolved_model
    assert_equal 1, run.attempt_count
    assert_equal "Sensitive prompt that must not persist".length, run.input_character_count
    assert_equal 64, run.input_digest.length
    assert_equal "Generated".length, run.output_character_count
    assert_equal 64, run.output_digest.length
    assert_equal "completed", attempt.status
    assert_equal "primary", attempt.kind
    assert_equal "test", attempt.provider
    assert_equal "balanced", attempt.model
    refute_includes run.attributes.values, "Sensitive prompt that must not persist"
    refute_includes attempt.attributes.values, "Sensitive prompt that must not persist"
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM recording_studio_events")
  end

  def test_generate_persists_only_sanitized_host_attribution_snapshots
    RecordingStudioAI.configuration.attribution_snapshotter = lambda do |role:, value:|
      { label: "#{role}-#{value.id}", api_key: "secret" }
    end

    generate_response = RecordingStudioAI.generate(
      prompt: "Summarize", root_recording: @root_recording, initiator: @initiator
    )

    assert generate_response.success?
    assert_equal(
      { "label" => "initiator-17", "api_key" => "[REDACTED]" },
      generate_response.run.initiator_snapshot
    )
  end

  def test_adapter_failure_is_normalized_and_does_not_persist_exception_payload
    RecordingStudioAI.configuration.adapters[:test] = FailingAdapter.new

    response = RecordingStudioAI.generate(
      prompt: "Summarize",
      root_recording: @root_recording,
      initiator: @initiator
    )

    refute response.success?
    assert_equal "provider_error", response.error.category
    assert_equal "Adapter execution failed.", response.error.message
    assert_equal "failed", RecordingStudioAI::Run.first.status
    assert_equal "failed", RecordingStudioAI::Attempt.first.status
    refute_includes RecordingStudioAI::Run.first.attributes.values, "secret provider payload"
    refute_includes RecordingStudioAI::Attempt.first.attributes.values, "secret provider payload"
  end

  private

  def configured_configuration
    RecordingStudioAI::Configuration.new.tap do |configuration|
      configuration.attribution_validator = ->(**) {}
      configuration.authorization_handler = ->(**) { true }
      configuration.adapters[:test] = @adapter
      configuration.allowed_provider_overrides = [:test]
      configuration.profiles[:medium] = [
        { provider: :test, model: "balanced", capabilities: %i[generation] }
      ]
    end
  end

  def bootstrap_external_recording_studio_table
    ActiveRecord::Base.connection.create_table(:recording_studio_recordings) do |table|
      table.timestamps
    end
    ActiveRecord::Base.connection.create_table(:recording_studio_events) do |table|
      table.references :recording
      table.string :action
    end
  end

  def create_recording_id
    ActiveRecord::Base.connection.insert(
      "INSERT INTO recording_studio_recordings (created_at, updated_at) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
  end
end
