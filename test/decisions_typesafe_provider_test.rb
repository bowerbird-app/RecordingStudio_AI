# frozen_string_literal: true

require "test_helper"
require "json"

class DecisionsTypeSafeProviderTest < Minitest::Test
  DECISION_CAPABILITIES = %i[decision decision_choice decision_score decision_noul].freeze

  class Client
    attr_reader :requests

    def initialize(body: nil, error: nil)
      @body = body
      @error = error
      @requests = []
    end

    def decide(model:, state:, questions:)
      requests << { model: model, state: state, questions: questions }
      raise @error if @error

      @body
    end
  end

  Unexpected = Class.new(StandardError)

  def test_decide_translates_every_question_kind_onto_the_documented_wire_shape
    client = Client.new(body: full_body)
    adapter = adapter_for(client)

    adapter.decide(request: full_request, candidate: candidate)

    request = client.requests.fetch(0)
    assert_equal 1, client.requests.length
    assert_equal "jev-latest", request.fetch(:model)
    assert_equal "Article body.", request.fetch(:state)
    assert_equal(
      {
        "mentions_target" => { type: "noul", instructions: "Mentioned?" },
        "coverage_type" => {
          type: "choice",
          instructions: "Which?",
          criteria: { "feature" => "A substantial feature", "mention" => nil }
        },
        "relevance" => {
          type: "score",
          instructions: "How relevant?",
          criteria: ["Not relevant", "Weakly relevant", "Clearly relevant", "Primarily about the target"]
        },
        "described" => {
          type: "noul",
          instructions: "Described?",
          criteria: { "true" => "It is", "false" => "It is not" }
        }
      },
      request.fetch(:questions)
    )
  end

  def test_decide_returns_typed_answers_keyed_by_the_callers_own_keys
    result = adapter_for(Client.new(body: full_body)).decide(request: full_request, candidate: candidate)

    assert_instance_of RecordingStudioAI::Providers::DecisionResult, result
    assert_predicate result, :success?
    assert_nil result.error
    assert_equal 4, result.answers.length

    noul = result.answers.fetch(:mentions_target)
    assert_instance_of RecordingStudioAI::Decisions::NoulAnswer, noul
    assert_equal 0.96, noul.probability

    choice = result.answers.fetch("coverage_type")
    assert_instance_of RecordingStudioAI::Decisions::ChoiceAnswer, choice
    assert_equal :feature, choice.choice
    assert_equal({ :feature => 0.82, "mention" => 0.18 }, choice.probabilities)
    assert_equal 0.91, choice.confidence

    score = result.answers.fetch(:relevance)
    assert_instance_of RecordingStudioAI::Decisions::ScoreAnswer, score
    assert_equal 2.7, score.score
    assert_equal({ "0" => "Not relevant", "3" => "Primarily about the target" }, score.legend)
    assert_equal({ "0" => 0.05, "3" => 0.55 }, score.probabilities)
    assert_equal 0.77, score.confidence

    assert_equal 0.5, result.answers.fetch(:described).probability
  end

  def test_decide_maps_usage_sums_totals_and_leaves_cost_and_request_id_alone
    result = adapter_for(Client.new(body: full_body)).decide(request: full_request, candidate: candidate)

    assert_equal 120, result.usage.input_tokens
    assert_equal 8, result.usage.output_tokens
    assert_equal 128, result.usage.total_tokens
    assert_nil result.usage.cached_input_tokens
    assert_nil result.usage.reasoning_tokens
    assert_nil result.cost
    assert_nil result.provider_request_id
  end

  def test_decide_omits_the_total_when_either_token_count_is_missing
    body = full_body.merge("usage" => { "input_tokens" => 120 })
    result = adapter_for(Client.new(body: body)).decide(request: full_request, candidate: candidate)

    assert_equal 120, result.usage.input_tokens
    assert_nil result.usage.output_tokens
    assert_nil result.usage.total_tokens
  end

  def test_decide_omits_usage_entirely_when_the_provider_reports_none
    body = full_body.except("usage")
    result = adapter_for(Client.new(body: body)).decide(request: full_request, candidate: candidate)

    assert_nil result.usage
    assert_predicate result, :success?
  end

  def test_decide_reports_the_served_model_without_changing_the_registry_model
    result = adapter_for(Client.new(body: full_body)).decide(request: full_request, candidate: candidate)

    assert_equal({ "served_model" => "jev-1.13.0" }, result.metadata)
    assert_equal(
      { "model" => "jev-1.13.0", "status" => "completed",
        "usage" => { "input_tokens" => 120, "output_tokens" => 8, "total_tokens" => 128,
                     "cached_input_tokens" => nil, "reasoning_tokens" => nil } },
      result.retention_snapshot
    )
    assert_equal "jev-latest", candidate.model
  end

  def test_decide_omits_served_model_when_the_provider_does_not_report_one
    body = full_body.except("model")
    result = adapter_for(Client.new(body: body)).decide(request: full_request, candidate: candidate)

    assert_empty result.metadata
    refute result.retention_snapshot.key?("model")
  end

  def test_decide_normalizes_expected_http_errors_without_raising
    {
      401 => %w[authentication http_401],
      403 => %w[authorization http_403],
      429 => %w[rate_limit http_429],
      400 => %w[invalid_request http_400],
      503 => %w[provider_unavailable http_503]
    }.each do |status, (category, code)|
      error = RecordingStudioAI::ProviderClients::TypeSafe::HttpError.new(
        status: status, code: "typesafe_code", provider_message: "sensitive provider payload"
      )
      result = adapter_for(Client.new(error: error)).decide(request: full_request, candidate: candidate)

      assert_instance_of RecordingStudioAI::Providers::DecisionResult, result
      refute_predicate result, :success?
      assert_equal category, result.error.category
      assert_equal code, result.error.code
      assert_equal "typesafe", result.error.provider
      assert_equal "typesafe_code", result.error.provider_code
      assert_empty result.answers
      refute_includes JSON.generate(result.error.to_h), "sensitive provider payload"
      refute_includes JSON.generate(result.retention_snapshot), "sensitive provider payload"
    end
  end

  def test_decide_marks_retryable_and_non_retryable_http_failures
    assert retryable_for?(429), "rate limits are retryable"
    assert retryable_for?(503), "provider outages are retryable"
    refute retryable_for?(401), "authentication failures are not retryable"
    refute retryable_for?(400), "invalid requests are not retryable"
  end

  def test_decide_lets_unexpected_errors_escape_for_containment_upstream
    adapter = adapter_for(Client.new(error: Unexpected.new("secret provider payload")))

    error = assert_raises(Unexpected) { adapter.decide(request: full_request, candidate: candidate) }
    assert_equal "secret provider payload", error.message
  end

  def test_decide_turns_malformed_success_bodies_into_a_non_retryable_invalid_response
    {
      "non-hash body" => "not json",
      "missing answers" => { "model" => "jev-1.13.0" },
      "non-hash answers" => { "answers" => [] },
      "missing answer" => { "answers" => {} },
      "unrequested key" => { "answers" => { "other" => { "type" => "noul", "noul" => 0.5 } } },
      "kind mismatch" => { "answers" => { "verdict" => { "type" => "choice", "choice" => "feature" } } },
      "non-hash answer" => { "answers" => { "verdict" => 0.5 } },
      "probability above one" => { "answers" => { "verdict" => { "type" => "noul", "noul" => 1.2 } } },
      "probability below zero" => { "answers" => { "verdict" => { "type" => "noul", "noul" => -0.1 } } },
      "non-numeric probability" => { "answers" => { "verdict" => { "type" => "noul", "noul" => "0.5" } } },
      "blank model" => { "model" => "  ", "answers" => { "verdict" => { "type" => "noul", "noul" => 0.5 } } },
      "negative usage" => {
        "answers" => { "verdict" => { "type" => "noul", "noul" => 0.5 } },
        "usage" => { "input_tokens" => -1 }
      }
    }.each do |label, body|
      result = adapter_for(Client.new(body: body)).decide(request: noul_request, candidate: candidate)

      assert_instance_of RecordingStudioAI::Providers::DecisionResult, result, label
      refute_predicate result, :success?
      assert_equal "invalid_response", result.error.category, label
      assert_equal "invalid_decision_payload", result.error.code, label
      assert_equal "Provider returned an unusable decision payload.", result.error.message
      refute_predicate result.error, :retryable?, label
      assert_empty result.answers, label
      assert_equal "failed", result.retention_snapshot.fetch("status"), label
      assert_equal "invalid_response", result.retention_snapshot.dig("error", "category"), label
    end
  end

  def test_decide_rejects_choice_answers_outside_the_requested_criteria
    body = {
      "answers" => {
        "coverage_type" => {
          "type" => "choice", "choice" => "invented",
          "probabilities" => { "feature" => 1.0 }, "confidence" => 0.9
        }
      }
    }
    result = adapter_for(Client.new(body: body)).decide(request: choice_request, candidate: candidate)

    refute_predicate result, :success?
    assert_equal "invalid_response", result.error.category
  end

  def test_decide_rejects_choice_probability_keys_outside_the_requested_criteria
    body = {
      "answers" => {
        "coverage_type" => {
          "type" => "choice", "choice" => "feature",
          "probabilities" => { "invented" => 1.0 }, "confidence" => 0.9
        }
      }
    }
    result = adapter_for(Client.new(body: body)).decide(request: choice_request, candidate: candidate)

    refute_predicate result, :success?
    assert_equal "invalid_response", result.error.category
  end

  def test_decide_rejects_score_legend_and_probability_keys_outside_the_requested_scale
    {
      "invented legend index" => { "9" => "Not relevant" },
      "padded index" => { "00" => "Not relevant" },
      "mismatched label" => { "0" => "Something else" }
    }.each do |label, legend|
      body = {
        "answers" => {
          "relevance" => {
            "type" => "score", "score" => 1, "legend" => legend,
            "probabilities" => { "0" => 1.0 }, "confidence" => 0.5
          }
        }
      }
      result = adapter_for(Client.new(body: body)).decide(request: score_request, candidate: candidate)

      refute_predicate result, :success?, label
      assert_equal "invalid_response", result.error.category, label
    end

    body = {
      "answers" => {
        "relevance" => {
          "type" => "score", "score" => 1, "legend" => { "0" => "Not relevant" },
          "probabilities" => { "9" => 1.0 }, "confidence" => 0.5
        }
      }
    }
    result = adapter_for(Client.new(body: body)).decide(request: score_request, candidate: candidate)

    refute_predicate result, :success?
    assert_equal "invalid_response", result.error.category
  end

  def test_encoder_and_decoder_reject_an_unknown_question_type
    mystery = Object.new
    mystery.define_singleton_method(:type) { :mystery }

    assert_raises(ArgumentError) do
      RecordingStudioAI::Providers::TypeSafe::QuestionEncoder.encode(mystery)
    end
    assert_raises(RecordingStudioAI::Providers::TypeSafe::AnswerDecoder::InvalidResponse) do
      RecordingStudioAI::Providers::TypeSafe::AnswerDecoder.decode_answer(
        { "type" => "mystery" }, mystery, "verdict"
      )
    end
  end

  def test_decide_rejects_scores_that_are_not_finite_numbers_on_the_requested_scale
    ["2", nil, Float::INFINITY, -1, 4].each do |score|
      body = {
        "answers" => {
          "relevance" => {
            "type" => "score", "score" => score, "legend" => { "0" => "Not relevant" },
            "probabilities" => { "0" => 1.0 }, "confidence" => 0.5
          }
        }
      }
      result = adapter_for(Client.new(body: body)).decide(request: score_request, candidate: candidate)

      refute_predicate result, :success?, "score #{score.inspect} must be rejected"
      assert_equal "invalid_response", result.error.category
    end
  end

  def test_typesafe_is_configured_by_an_api_key_or_an_injected_client
    configuration = RecordingStudioAI::Configuration.new
    refute_predicate RecordingStudioAI::Providers::TypeSafe.new(configuration: configuration), :configured?

    configuration.typesafe_api_key = "secret-key"
    assert_predicate RecordingStudioAI::Providers::TypeSafe.new(configuration: configuration), :configured?

    injected = RecordingStudioAI::Configuration.new
    injected.typesafe_client = Client.new(body: full_body)
    assert_predicate RecordingStudioAI::Providers::TypeSafe.new(configuration: injected), :configured?
  end

  def test_internal_typesafe_client_posts_system_one_with_a_bearer_token_and_json_body
    client = RecordingStudioAI::ProviderClients::TypeSafe.new(api_key: "secret-key", timeout: 5)
    captured_request = nil
    captured_options = nil
    response = json_response(Net::HTTPOK, "200", '{"model":"jev-1.13.0","answers":{}}')
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      response
    end

    body = Net::HTTP.stub(:start, lambda { |*arguments, **options, &block|
      captured_options = [arguments, options]
      block.call(http)
    }) do
      client.decide(
        model: "jev-latest",
        state: "Sensitive state",
        questions: { "verdict" => { type: "noul", instructions: "Sensitive instruction" } }
      )
    end

    assert_equal({ "model" => "jev-1.13.0", "answers" => {} }, body)
    assert_equal "/v1/systemone", captured_request.path
    assert_equal "Bearer secret-key", captured_request["Authorization"]
    assert_equal "application/json", captured_request["Content-Type"]
    assert_equal(
      { "model" => "jev-latest", "state" => "Sensitive state",
        "questions" => { "verdict" => { "type" => "noul", "instructions" => "Sensitive instruction" } } },
      JSON.parse(captured_request.body)
    )
    assert_equal ["api.typesafe.ai", 443], captured_options.first
    assert_equal({ use_ssl: true, open_timeout: 5, read_timeout: 5 }, captured_options.last)
    refute_includes captured_request.path, "secret-key"
    refute_includes captured_request.path, "Sensitive"
  end

  def test_internal_typesafe_client_raises_http_error_with_status_code_and_provider_message
    error = client_http_error(Net::HTTPTooManyRequests, "429",
                              '{"error":{"code":"rate_limited","message":"Slow down"}}')

    assert_equal 429, error.status
    assert_equal "rate_limited", error.code
    assert_equal "Slow down", error.provider_message
    assert_equal "TypeSafe request failed", error.message
  end

  def test_internal_typesafe_client_reads_flat_error_bodies
    error = client_http_error(Net::HTTPBadRequest, "400", '{"code":"bad_state","message":"State too long"}')

    assert_equal 400, error.status
    assert_equal "bad_state", error.code
    assert_equal "State too long", error.provider_message
  end

  def test_internal_typesafe_client_still_raises_http_error_for_non_json_error_bodies
    ["<html>502 Bad Gateway</html>", "", "[1,2,3]"].each do |body|
      error = client_http_error(Net::HTTPBadGateway, "502", body)

      assert_equal 502, error.status
      assert_nil error.code
      assert_nil error.provider_message
    end
  end

  private

  def json_response(klass, code, body)
    response = klass.new("1.1", code, "Response")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    response
  end

  def client_http_error(klass, code, body)
    client = RecordingStudioAI::ProviderClients::TypeSafe.new(api_key: "secret-key", timeout: 5)
    response = json_response(klass, code, body)
    http = Object.new
    http.define_singleton_method(:request) { |_request| response }

    Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      assert_raises(RecordingStudioAI::ProviderClients::TypeSafe::HttpError) do
        client.decide(model: "jev-latest", state: "state", questions: {})
      end
    end
  end

  def retryable_for?(status)
    error = RecordingStudioAI::ProviderClients::TypeSafe::HttpError.new(status: status)
    adapter_for(Client.new(error: error)).decide(request: full_request, candidate: candidate).error.retryable?
  end

  def adapter_for(client)
    configuration = RecordingStudioAI::Configuration.new
    configuration.typesafe_client = client
    RecordingStudioAI::Providers::TypeSafe.new(configuration: configuration)
  end

  def candidate
    RecordingStudioAI::Candidate.new(provider: :typesafe, model: "jev-latest", capabilities: DECISION_CAPABILITIES)
  end

  def request_for(questions)
    {
      state: RecordingStudioAI::Decisions::State.parse("Article body."),
      questions: RecordingStudioAI::Decisions::QuestionSet.parse(questions)
    }
  end

  def full_request
    request_for(
      :mentions_target => { type: :noul, instructions: "Mentioned?" },
      "coverage_type" => {
        type: :choice, instructions: "Which?",
        criteria: { feature: "A substantial feature", "mention" => nil }
      },
      :relevance => {
        type: :score, instructions: "How relevant?",
        criteria: ["Not relevant", "Weakly relevant", "Clearly relevant", "Primarily about the target"]
      },
      :described => {
        type: :noul, instructions: "Described?",
        criteria: { true => "It is", false => "It is not" }
      }
    )
  end

  def noul_request
    request_for(verdict: { type: :noul, instructions: "Mentioned?" })
  end

  def choice_request
    request_for(coverage_type: { type: :choice, instructions: "Which?", criteria: { feature: "Feature" } })
  end

  def score_request
    request_for(relevance: { type: :score, instructions: "How relevant?", criteria: ["Not relevant", "Relevant"] })
  end

  def full_body
    {
      "model" => "jev-1.13.0",
      "answers" => {
        "mentions_target" => { "type" => "noul", "noul" => 0.96 },
        "coverage_type" => {
          "type" => "choice", "choice" => "feature",
          "probabilities" => { "feature" => 0.82, "mention" => 0.18 }, "confidence" => 0.91
        },
        "relevance" => {
          "type" => "score", "score" => 2.7,
          "legend" => { "0" => "Not relevant", "3" => "Primarily about the target" },
          "probabilities" => { "0" => 0.05, "3" => 0.55 }, "confidence" => 0.77
        },
        "described" => { "type" => "noul", "noul" => 0.5 }
      },
      "usage" => { "input_tokens" => 120, "output_tokens" => 8 }
    }
  end
end
