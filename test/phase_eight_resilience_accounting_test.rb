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

class PhaseEightResilienceAccountingTest < Minitest::Test
  Actor = Struct.new(:id)

  class QueueProvider < RecordingStudioAI::Providers::Base
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def generate(request:, candidate:)
      calls << { request: request, candidate: candidate }
      @results.shift || raise("unexpected provider call")
    end
  end

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    bootstrap_external_recording_studio_table
    ActiveRecord::Migration.suppress_messages do
      CreateRecordingStudioAIPersistenceTables.migrate(:up)
      AddPromptAttributionToRecordingStudioAIRuns.migrate(:up)
      RemoveCorrelationIdsFromRecordingStudioAI.migrate(:up)
    end

    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(51)
    @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    configuration = RecordingStudioAI::Configuration.new
    configuration.attribution_validator = ->(**) {}
    configuration.authorization_handler = ->(**) { true }
    RecordingStudioAI.instance_variable_set(:@configuration, configuration)
  end

  def teardown
    RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end

  def test_retry_then_provider_fallback_tracks_attempt_kinds_and_aggregates_accounting
    first_provider = QueueProvider.new(
      failed_result("rate_limit", usage: usage(10, 0), cost: cost(100)),
      failed_result("timeout", usage: usage(4, 0), cost: cost(40))
    )
    second_provider = QueueProvider.new(
      success_result("Fallback answer", usage: usage(8, 6), cost: cost(90))
    )
    configure_candidates(
      first: first_provider,
      second: second_provider,
      profile: :medium
    )

    response = generate

    assert response.success?
    assert_equal "Fallback answer", response.text
    assert_equal "second", response.provider
    assert_equal %w[primary retry fallback], response.attempts.map(&:kind)
    assert_equal %w[failed failed completed], response.attempts.map(&:status)
    assert_equal 22, response.usage.input_tokens
    assert_equal 6, response.usage.output_tokens
    assert_equal 28, response.usage.total_tokens
    assert_equal 230, response.cost.amount
    assert_equal 3, response.run.attempt_count
    assert_equal 1, response.run.retry_count
    assert_equal 1, response.run.fallback_count
    assert_equal 22, response.run.input_tokens
    assert_equal %w[first first second], RecordingStudioAI::Attempt.order(:sequence).pluck(:provider)
  end

  def test_retry_backoff_is_exponential_bounded_and_deterministic
    delays = []
    configuration = RecordingStudioAI.configuration
    configuration.maximum_attempts = 3
    configuration.maximum_retries_per_candidate = 2
    configuration.retry_backoff_base = 2
    configuration.retry_backoff_max = 3
    configuration.retry_jitter = 0
    configuration.retry_sleeper = ->(seconds) { delays << seconds }
    provider = QueueProvider.new(
      failed_result("timeout"), failed_result("timeout"), success_result("Recovered")
    )
    configure_single_candidate(:medium, :retry_provider, provider)

    response = generate

    assert response.success?
    assert_equal [2.0, 3.0], delays
    assert_equal %w[primary retry retry], response.attempts.map(&:kind)
  end

  def test_provider_request_timeout_has_distinct_normalized_code
    provider = Class.new(RecordingStudioAI::Providers::Base) do
      def generate(request:, candidate:)
        Queue.new.pop
      end
    end.new
    RecordingStudioAI.configuration.request_timeout = 0.01
    RecordingStudioAI.configuration.maximum_retries_per_candidate = 0
    configure_single_candidate(:medium, :slow_provider, provider)

    response = generate

    refute response.success?
    assert_equal "timeout", response.error.category
    assert_equal "provider_timeout", response.error.code
  end

  def test_catalog_estimates_cost_when_provider_reports_usage_without_cost
    provider = QueueProvider.new(success_result("Estimated", usage: usage(10, 5)))
    configure_single_candidate(:medium, :catalog_provider, provider)
    RecordingStudioAI.configuration.cost_catalogs = {
      catalog_provider: {
        "catalog_provider-model" => { input_tokens: 2_000_000, output_tokens: 4_000_000, currency: "USD" }
      }
    }

    response = generate

    assert response.success?
    assert_equal 40, response.cost.amount
    assert response.cost.estimated?
    assert_equal "catalog", response.cost.source
  end

  def test_provider_and_profile_fallback_limits_are_independent
    configuration = RecordingStudioAI.configuration
    configuration.maximum_retries_per_candidate = 0
    configuration.maximum_provider_fallbacks = 0
    medium_provider = QueueProvider.new(failed_result("timeout"))
    other_medium_provider = QueueProvider.new(success_result("must not run"))
    low_provider = QueueProvider.new(success_result("lower tier"))
    configuration.providers = {
      medium_provider: medium_provider,
      other_medium_provider: other_medium_provider,
      low_provider: low_provider
    }
    configuration.profiles[:medium] = [
      { provider: :medium_provider, model: "medium-model", capabilities: %i[generation] },
      { provider: :other_medium_provider, model: "other-medium-model", capabilities: %i[generation] }
    ]
    configuration.profiles[:low] = [
      { provider: :low_provider, model: "low-model", capabilities: %i[generation] }
    ]
    configuration.profile_fallbacks = { medium: [:low] }

    response = generate

    assert response.success?
    assert_equal %w[primary fallback], response.attempts.map(&:kind)
    assert_empty other_medium_provider.calls
    assert_equal 1, low_provider.calls.length
  end

  def test_profile_fallback_limit_bounds_explicit_mappings
    configuration = RecordingStudioAI.configuration
    configuration.maximum_retries_per_candidate = 0
    configuration.maximum_profile_fallbacks = 0
    medium_provider = QueueProvider.new(failed_result("timeout"))
    low_provider = QueueProvider.new(success_result("must not run"))
    configure_single_candidate(:medium, :medium_provider, medium_provider)
    configure_single_candidate(:low, :low_provider, low_provider)
    configuration.profile_fallbacks = { medium: [:low] }

    response = generate

    refute response.success?
    assert_equal ["primary"], response.attempts.map(&:kind)
    assert_empty low_provider.calls
  end

  def test_non_retryable_failure_stops_without_retry_or_fallback
    first_provider = QueueProvider.new(failed_result("invalid_request", retryable: false))
    second_provider = QueueProvider.new(success_result("must not run"))
    configure_candidates(first: first_provider, second: second_provider, profile: :medium)

    response = generate

    refute response.success?
    assert_equal 1, response.attempts.length
    assert_equal "primary", response.attempts.first.kind
    assert_equal 1, first_provider.calls.length
    assert_empty second_provider.calls
    assert_equal 0, response.run.retry_count
    assert_equal 0, response.run.fallback_count
  end

  def test_global_attempt_bound_wins_over_retry_and_fallback_limits
    configuration = RecordingStudioAI.configuration
    configuration.maximum_attempts = 2
    configuration.maximum_retries_per_candidate = 3
    configuration.maximum_provider_fallbacks = 3
    first_provider = QueueProvider.new(failed_result("timeout"), failed_result("timeout"))
    second_provider = QueueProvider.new(success_result("must not run"))
    configure_candidates(first: first_provider, second: second_provider, profile: :medium)

    response = generate

    refute response.success?
    assert_equal %w[primary retry], response.attempts.map(&:kind)
    assert_equal 2, first_provider.calls.length
    assert_empty second_provider.calls
    assert_equal 2, response.run.attempt_count
  end

  def test_profile_tier_fallback_requires_explicit_configuration
    medium_provider = QueueProvider.new(failed_result("timeout"), failed_result("timeout"))
    low_provider = QueueProvider.new(success_result("lower tier"))
    configure_single_candidate(:medium, :medium_provider, medium_provider)
    configure_single_candidate(:low, :low_provider, low_provider)

    without_fallback = generate
    refute without_fallback.success?
    assert_empty low_provider.calls

    reset_execution_records
    medium_provider = QueueProvider.new(failed_result("timeout"), failed_result("timeout"))
    low_provider = QueueProvider.new(success_result("lower tier"))
    configure_single_candidate(:medium, :medium_provider, medium_provider)
    configure_single_candidate(:low, :low_provider, low_provider)
    RecordingStudioAI.configuration.profile_fallbacks = { medium: [:low] }

    with_fallback = generate
    assert with_fallback.success?
    assert_equal "lower tier", with_fallback.text
    assert_equal %w[primary retry fallback], with_fallback.attempts.map(&:kind)
    assert_equal "low", RecordingStudioAI::Attempt.order(:sequence).last.profile_key
  end

  def test_mixed_currency_cost_remains_unknown_while_usage_still_aggregates
    first_provider = QueueProvider.new(
      failed_result("timeout", usage: usage(3, 0), cost: cost(20, currency: "USD")),
      success_result("done", usage: usage(4, 5), cost: cost(30, currency: "EUR"))
    )
    configure_single_candidate(:medium, :first, first_provider)

    response = generate

    assert response.success?
    assert_equal 12, response.usage.total_tokens
    assert_nil response.cost
  end

  def test_partial_usage_keeps_each_incomplete_aggregate_unknown
    partial_usage = RecordingStudioAI::Contracts::Usage.new(
      input_tokens: 3,
      output_tokens: 0,
      total_tokens: nil,
      cached_input_tokens: 0,
      reasoning_tokens: nil
    )
    complete_usage = RecordingStudioAI::Contracts::Usage.new(
      input_tokens: 4,
      output_tokens: 5,
      total_tokens: 9,
      cached_input_tokens: 0,
      reasoning_tokens: 2
    )
    provider = QueueProvider.new(
      failed_result("timeout", usage: partial_usage),
      success_result("done", usage: complete_usage)
    )
    configure_single_candidate(:medium, :first, provider)

    response = generate

    assert_equal 7, response.usage.input_tokens
    assert_equal 5, response.usage.output_tokens
    assert_nil response.usage.total_tokens
    assert_equal 0, response.usage.cached_input_tokens
    assert_nil response.usage.reasoning_tokens
    assert_nil response.run.total_tokens
    assert_nil response.run.reasoning_tokens
  end

  private

  def generate
    RecordingStudioAI.generate(
      prompt: "Resilient request",
      root_recording: @root_recording,
      initiator: @initiator
    )
  end

  def configure_candidates(first:, second:, profile:)
    configuration = RecordingStudioAI.configuration
    configuration.providers = { first: first, second: second }
    configuration.profiles[profile] = [
      { provider: :first, model: "first-model", capabilities: %i[generation] },
      { provider: :second, model: "second-model", capabilities: %i[generation] }
    ]
  end

  def configure_single_candidate(profile, provider_key, provider)
    configuration = RecordingStudioAI.configuration
    configuration.providers[provider_key] = provider
    configuration.profiles[profile] = [
      { provider: provider_key, model: "#{provider_key}-model", capabilities: %i[generation] }
    ]
  end

  def success_result(text, usage: nil, cost: nil)
    RecordingStudioAI::Providers::Result.new(
      text: text,
      usage: usage,
      cost: cost,
      finish_reason: "stop"
    )
  end

  def failed_result(category, retryable: true, usage: nil, cost: nil)
    RecordingStudioAI::Providers::Result.new(
      usage: usage,
      cost: cost,
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: category,
        code: category,
        message: "Provider failed.",
        retryable: retryable,
        provider: "first"
      )
    )
  end

  def usage(input_tokens, output_tokens)
    RecordingStudioAI::Contracts::Usage.new(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    )
  end

  def cost(amount, currency: "USD")
    RecordingStudioAI::Contracts::Cost.new(
      amount: amount,
      currency: currency,
      estimated: false,
      source: "provider"
    )
  end

  def reset_execution_records
    RecordingStudioAI::Attempt.delete_all
    RecordingStudioAI::Run.delete_all
  end

  def bootstrap_external_recording_studio_table
    ActiveRecord::Base.connection.create_table(:recording_studio_recordings) do |table|
      table.timestamps
    end
  end

  def create_recording_id
    ActiveRecord::Base.connection.insert(
      "INSERT INTO recording_studio_recordings (created_at, updated_at) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
  end
end
