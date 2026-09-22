# frozen_string_literal: true

require "test_helper"
require "json"

class DecisionsExecutionTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  STATE = "ACME Architects won the civic prize for the new library."
  DECISION_CAPABILITIES = %i[decision decision_choice decision_score decision_noul].freeze

  class DecisionProvider < RecordingStudioAI::Providers::Base
    attr_reader :requests

    def initialize(*results)
      super()
      @results = results
      @requests = []
    end

    def decide(request:, candidate:)
      requests << { request: request, candidate: candidate }
      result = @results.shift
      raise "unexpected decide call" unless result
      raise result if result.is_a?(Exception)

      result
    end
  end

  class RaisingDecisionProvider < RecordingStudioAI::Providers::Base
    def decide(**)
      raise "secret decision payload"
    end
  end

  class GenerationOnlyProvider < RecordingStudioAI::Providers::Base
    def generate(**)
      RecordingStudioAI::Providers::Result.new(text: "Generated", finish_reason: "stop")
    end
  end

  class WrongResultProvider < RecordingStudioAI::Providers::Base
    def decide(**)
      RecordingStudioAI::Providers::Result.new(text: "Generated", finish_reason: "stop")
    end
  end

  def host_events?
    true
  end

  def before_connect
    ActiveRecord::Encryption.configure(
      primary_key: "decisions-primary-key",
      deterministic_key: "decisions-deterministic-key",
      key_derivation_salt: "decisions-key-derivation-salt"
    )
  end

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(23)
    @provider = DecisionProvider.new(success_result)
    isolate_allow_all_configuration!
    configure_decision_candidate(@provider)
  end

  def test_decide_returns_typed_answers_keyed_by_the_callers_question_keys
    response = decide

    assert_predicate response, :success?
    assert_instance_of RecordingStudioAI::Contracts::DecisionResponse, response
    assert_equal "decision", response.operation
    assert_equal :medium, response.profile
    assert_equal "decisive", response.provider
    assert_equal "jev-test", response.model
    assert_equal "jev-1.13.0", response.served_model
    assert_equal "jev-1.13.0", response.to_h.fetch(:served_model)
    assert_equal "coverage_triage", response.purpose
    assert_equal 0.96, response.answers[:mentions_target].probability
    assert_equal :feature, response.answers[:coverage_type].choice
    assert_equal({ feature: 0.82, mention: 0.18 }, response.answers[:coverage_type].probabilities)
    assert_equal 0.91, response.answers[:coverage_type].confidence
    assert_equal 2.7, response.answers[:relevance].score
    assert_equal({ "0" => "Not relevant", "3" => "Primarily about the target" }, response.answers[:relevance].legend)
    assert_equal 120, response.usage.input_tokens
    assert_nil response.cost
    assert_nil response.error
  end

  def test_decide_passes_typed_state_and_questions_to_the_provider_without_prompt_fields
    decide

    request = @provider.requests.fetch(0).fetch(:request)

    assert_instance_of RecordingStudioAI::Decisions::State::Text, request.fetch(:state)
    assert_equal STATE, request.fetch(:state).value
    assert_instance_of RecordingStudioAI::Decisions::QuestionSet, request.fetch(:questions)
    assert_equal %i[noul choice score], request.fetch(:questions).types
    %i[prompt messages system_instruction schema stream attachments provider_native_tools custom_tools].each do |key|
      refute request.key?(key), "#{key} is a generation channel"
    end
    assert_equal :decisive, @provider.requests.fetch(0).fetch(:candidate).provider
    assert_equal "jev-test", @provider.requests.fetch(0).fetch(:candidate).model
  end

  def test_decide_persists_a_decision_run_without_the_state_or_question_text
    response = decide
    run = RecordingStudioAI::Run.first
    attempt = RecordingStudioAI::Attempt.first

    assert_equal "decision", run.operation
    assert_equal "completed", run.status
    assert_equal "medium", run.profile_key
    assert_equal "decisive", run.resolved_provider
    assert_equal "jev-test", run.resolved_model
    assert_equal "coverage_triage", run.purpose
    assert_equal STATE.length, run.input_character_count
    assert_equal 1, run.attempt_count
    assert_equal 0, run.citation_count
    refute run.web_search_requested
    refute run.web_search_used
    assert_equal 0, run.attachment_count
    assert_equal "completed", attempt.status
    assert_equal "primary", attempt.kind
    assert_nil attempt.finish_reason
    assert_nil attempt.provider_request_id
    assert_equal run, response.run

    serialized = JSON.generate([run.attributes, attempt.attributes])
    ["ACME Architects won", "Does this content", "What type of coverage", "A substantial feature",
     "Not relevant"].each do |secret|
      refute_includes serialized, secret
    end
  end

  def test_decide_records_the_answer_payload_size_as_the_output_character_count
    response = decide
    run = RecordingStudioAI::Run.first

    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM recording_studio_events")
    assert_equal JSON.generate(response.answers.to_serializable_h).length, run.output_character_count
    assert_equal 120, run.input_tokens
    assert_equal 8, run.output_tokens
    assert_equal 128, run.total_tokens
  end

  def test_decide_bang_returns_the_response_on_success
    response = RecordingStudioAI.decide!(**decision_arguments)

    assert_predicate response, :success?
    assert_equal 0.96, response.answers[:mentions_target].probability
  end

  def test_decide_bang_raises_execution_error_carrying_the_failed_response
    configure_decision_candidate(DecisionProvider.new(failed_result("provider_error", retryable: false)))

    error = assert_raises(RecordingStudioAI::Errors::ExecutionError) { RecordingStudioAI.decide!(**decision_arguments) }

    assert_instance_of RecordingStudioAI::Contracts::DecisionResponse, error.response
    refute_predicate error.response, :success?
    assert_equal "provider_error", error.response.error.category
    assert_empty error.response.answers
  end

  def test_failed_decision_persists_a_failed_run_and_no_answers
    configure_decision_candidate(DecisionProvider.new(failed_result("invalid_response", retryable: false)))

    response = decide

    refute_predicate response, :success?
    assert_equal "invalid_response", response.error.category
    assert_empty response.answers
    assert_equal "failed", RecordingStudioAI::Run.first.status
    assert_equal "invalid_response", RecordingStudioAI::Run.first.error_category
    assert_equal "failed", RecordingStudioAI::Attempt.first.status
    assert_nil RecordingStudioAI::Run.first.output_character_count
  end

  def test_decision_retries_a_retryable_failure_on_the_same_candidate
    RecordingStudioAI.configuration.retry_sleeper = ->(_seconds) {}
    configure_decision_candidate(
      DecisionProvider.new(failed_result("rate_limit", retryable: true), success_result)
    )

    response = decide

    assert_predicate response, :success?
    assert_equal %w[primary retry], response.attempts.map(&:kind)
    assert_equal %w[failed completed], response.attempts.map(&:status)
    assert_equal 2, RecordingStudioAI::Run.first.attempt_count
    assert_equal 1, RecordingStudioAI::Run.first.retry_count
  end

  def test_decision_falls_back_to_the_next_decision_candidate_in_the_profile
    second = DecisionProvider.new(success_result)
    configuration = RecordingStudioAI.configuration
    configuration.maximum_retries_per_candidate = 0
    configuration.providers[:decisive] = DecisionProvider.new(failed_result("rate_limit", retryable: true))
    configuration.providers[:decisive_backup] = second
    configuration.profiles[:medium] = [
      { provider: :decisive, model: "jev-test", capabilities: DECISION_CAPABILITIES },
      { provider: :decisive_backup, model: "jev-backup", capabilities: DECISION_CAPABILITIES }
    ]

    response = decide

    assert_predicate response, :success?
    assert_equal "decisive_backup", response.provider
    assert_equal "jev-backup", response.model
    assert_equal %w[primary fallback], response.attempts.map(&:kind)
    assert_equal %w[failed completed], response.attempts.map(&:status)
    assert_equal 1, RecordingStudioAI::Run.first.fallback_count
    assert_equal 1, second.requests.length
  end

  def test_a_non_retryable_decision_failure_stops_before_the_next_candidate
    second = DecisionProvider.new(success_result)
    configuration = RecordingStudioAI.configuration
    configuration.providers[:decisive] = DecisionProvider.new(failed_result("invalid_response", retryable: false))
    configuration.providers[:decisive_backup] = second
    configuration.profiles[:medium] = [
      { provider: :decisive, model: "jev-test", capabilities: DECISION_CAPABILITIES },
      { provider: :decisive_backup, model: "jev-backup", capabilities: DECISION_CAPABILITIES }
    ]

    response = decide

    refute_predicate response, :success?
    assert_equal %w[primary], response.attempts.map(&:kind)
    assert_empty second.requests
  end

  def test_decision_contains_an_unexpected_provider_exception
    configure_decision_candidate(RaisingDecisionProvider.new)

    response = decide

    refute_predicate response, :success?
    assert_equal "provider_error", response.error.category
    assert_equal "Provider execution failed.", response.error.message
    refute_includes JSON.generate(RecordingStudioAI::Run.first.attributes), "secret decision payload"
    refute_includes JSON.generate(RecordingStudioAI::Attempt.first.attributes), "secret decision payload"
  end

  def test_a_generation_only_provider_reached_by_a_decision_fails_as_unsupported_operation
    configure_decision_candidate(GenerationOnlyProvider.new)

    response = decide

    refute_predicate response, :success?
    assert_equal "configuration", response.error.category
    assert_equal "unsupported_operation", response.error.code
    assert_equal "Provider does not implement the requested operation.", response.error.message
    refute_predicate response.error, :retryable?
    assert_equal 1, RecordingStudioAI::Attempt.count
    refute RecordingStudioAI::Attempt.first.retryable
  end

  def test_a_not_implemented_decide_fails_as_unsupported_operation
    configure_decision_candidate(DecisionProvider.new(NotImplementedError.new("no decide here")))

    response = decide

    refute_predicate response, :success?
    assert_equal "configuration", response.error.category
    assert_equal "unsupported_operation", response.error.code
  end

  def test_a_decision_candidate_returning_a_generation_result_fails_without_leaking_it
    configure_decision_candidate(WrongResultProvider.new)

    response = decide

    refute_predicate response, :success?
    assert_equal "provider_error", response.error.category
    assert_empty response.answers
  end

  def test_generate_cannot_select_a_decision_only_candidate
    response = RecordingStudioAI.generate(
      prompt: "Summarize", root_recording: @root_recording, initiator: @initiator
    )

    refute_predicate response, :success?
    assert_equal "unsupported_capability", response.error.category
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty @provider.requests
  end

  def test_decide_cannot_select_a_generation_only_candidate
    RecordingStudioAI.configuration.providers[:generative] = GenerationOnlyProvider.new
    RecordingStudioAI.configuration.profiles[:medium] = [
      { provider: :generative, model: "gpt-test", capabilities: %i[generation streaming structured_output] }
    ]

    response = decide

    refute_predicate response, :success?
    assert_equal "unsupported_capability", response.error.category
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_decide_authorizes_the_execute_action_with_the_decision_operation
    contexts = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, context:, **|
      contexts << [action, context]
      true
    end

    decide

    assert_equal ["recording_studio_ai.execute"], contexts.map(&:first)
    assert_equal(
      { "operation" => "decision", "profile" => "medium", "purpose" => "coverage_triage" },
      contexts.first.last
    )
  end

  def test_an_unauthorized_decision_creates_no_run_and_never_calls_the_provider
    RecordingStudioAI.configuration.authorization_handler = ->(**) { false }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { decide }

    assert_equal "authorization", error.code
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty @provider.requests
  end

  def test_decision_lifecycle_notifications_report_the_decision_operation
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Arecording_studio_ai\./) do |*arguments|
      event = ActiveSupport::Notifications::Event.new(*arguments)
      events << [event.name, event.payload]
    end

    decide

    names = events.map(&:first)
    assert_includes names, "recording_studio_ai.run.started"
    assert_includes names, "recording_studio_ai.run.completed"
    assert_includes names, "recording_studio_ai.attempt.completed"
    refute_includes names, "recording_studio_ai.stream.started"

    run_completed = events.find { |name, _payload| name == "recording_studio_ai.run.completed" }.last
    assert_equal "decision", run_completed.fetch(:operation)
    assert_equal "coverage_triage", run_completed.fetch(:purpose)
    refute_includes JSON.generate(events), STATE
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_retention_off_stores_no_decision_response
    RecordingStudioAI.configuration.retain_responses = false

    decide

    assert_equal 0, RecordingStudioAI::Response.count
  end

  def test_retention_on_stores_the_answers_only
    RecordingStudioAI.configuration.retain_responses = true

    decide
    retained = RecordingStudioAI::Response.first

    assert_equal "decision", retained.response_type
    assert_equal RecordingStudioAI::Attempt.first, retained.attempt
    assert_nil retained.content_text
    assert_equal "application/json", retained.content_type
    assert_nil retained.finish_reason
    assert retained.complete
    refute retained.truncated
    assert_nil retained.provider_response_id
    assert_in_delta 7.days.from_now, retained.expires_at, 2.seconds

    normalized = JSON.parse(retained.normalized_response)
    assert_equal(
      { "type" => "noul", "probability" => 0.96 },
      normalized.dig("answers", "mentions_target")
    )
    assert_equal "feature", normalized.dig("answers", "coverage_type", "choice")
    assert_equal 0.82, normalized.dig("answers", "coverage_type", "probabilities", "feature")
    assert_equal 2.7, normalized.dig("answers", "relevance", "score")
    assert_equal 120, normalized.dig("usage", "input_tokens")
    refute normalized.key?("text")
    refute normalized.key?("structured_data")
    refute normalized.key?("citations")

    assert_equal(
      { "model" => "jev-1.13.0", "status" => "completed" },
      JSON.parse(retained.raw_response).slice("model", "status")
    )
    serialized = JSON.generate(retained.attributes)
    ["ACME Architects won", "Does this content", "A substantial feature"].each do |secret|
      refute_includes serialized, secret
    end
  end

  def test_retention_on_stores_a_failed_decision_as_an_error_response
    RecordingStudioAI.configuration.retain_responses = true
    configure_decision_candidate(DecisionProvider.new(failed_result("provider_error", retryable: false)))

    decide
    retained = RecordingStudioAI::Response.first

    assert_equal "error", retained.response_type
    assert_nil retained.content_text
    refute retained.complete
    assert_equal "provider_error", JSON.parse(retained.normalized_response).dig("error", "category")
    refute JSON.parse(retained.normalized_response).key?("answers")
  end

  def test_decision_run_that_exceeds_the_execution_deadline_fails_without_an_attempt
    RecordingStudioAI.configuration.total_execution_timeout = 0

    response = decide

    refute_predicate response, :success?
    assert_instance_of RecordingStudioAI::Contracts::DecisionResponse, response
    assert_equal "timeout", response.error.category
    assert_equal "execution_deadline_exceeded", response.error.code
    assert_empty response.answers
    assert_equal "failed", RecordingStudioAI::Run.first.status
    assert_equal 0, RecordingStudioAI::Run.first.attempt_count
    assert_equal 0, RecordingStudioAI::Attempt.count
    assert_empty @provider.requests
  end

  def test_decision_metadata_redacts_decision_payload_keys
    response = decide(metadata: { state: STATE, criteria: %w[a b], feature: "pages" })

    assert_equal(
      { "state" => "[REDACTED]", "criteria" => "[REDACTED]", "feature" => "pages" },
      response.metadata
    )
    refute_includes JSON.generate(RecordingStudioAI::Run.first.metadata), STATE
  end

  private

  def decide(**overrides)
    RecordingStudioAI.decide(**decision_arguments, **overrides)
  end

  def decision_arguments
    {
      state: STATE,
      questions: {
        mentions_target: {
          type: :noul,
          instructions: "Does this content substantially mention ACME Architects?"
        },
        coverage_type: {
          type: :choice,
          instructions: "What type of coverage is this?",
          criteria: { feature: "A substantial feature about the target", mention: "A shorter mention" }
        },
        relevance: {
          type: :score,
          instructions: "How relevant is this content to the target?",
          criteria: ["Not relevant", "Weakly relevant", "Clearly relevant", "Primarily about the target"]
        }
      },
      profile: :medium,
      purpose: "coverage_triage",
      root_recording: @root_recording,
      initiator: @initiator
    }
  end

  def configure_decision_candidate(provider)
    configuration = RecordingStudioAI.configuration
    configuration.providers[:decisive] = provider
    configuration.profiles[:medium] = [
      { provider: :decisive, model: "jev-test", capabilities: DECISION_CAPABILITIES }
    ]
  end

  def question_set
    RecordingStudioAI::Decisions::QuestionSet.parse(decision_arguments.fetch(:questions))
  end

  def success_result
    RecordingStudioAI::Providers::DecisionResult.new(
      answers: RecordingStudioAI::Decisions::AnswerSet.from_canonical(
        question_set: question_set,
        answers: {
          "mentions_target" => RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.96),
          "coverage_type" => RecordingStudioAI::Decisions::ChoiceAnswer.new(
            choice: :feature, probabilities: { feature: 0.82, mention: 0.18 }, confidence: 0.91
          ),
          "relevance" => RecordingStudioAI::Decisions::ScoreAnswer.new(
            score: 2.7, legend: { "0" => "Not relevant", "3" => "Primarily about the target" },
            probabilities: { "0" => 0.05, "3" => 0.55 }, confidence: 0.77
          )
        }
      ),
      usage: RecordingStudioAI::Contracts::Usage.new(input_tokens: 120, output_tokens: 8, total_tokens: 128),
      metadata: { served_model: "jev-1.13.0" },
      retention_snapshot: { model: "jev-1.13.0", status: "completed" }
    )
  end

  def failed_result(category, retryable:)
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: category, code: "decision_#{category}", message: "Safe decision failure",
      retryable: retryable, provider: "decisive"
    )
    RecordingStudioAI::Providers::DecisionResult.new(
      error: error, retention_snapshot: { status: "failed", error: error.to_h }
    )
  end
end
