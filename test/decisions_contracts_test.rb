# frozen_string_literal: true

require "test_helper"

class DecisionsContractsTest < RecordingStudioAI::Test::IsolatedCase
  Actor = Struct.new(:id)

  def setup
    isolate_allow_all_configuration!
  end

  def test_state_parse_wraps_a_non_empty_string
    state = RecordingStudioAI::Decisions::State.parse("An article about ACME Architects.")

    assert_instance_of RecordingStudioAI::Decisions::State::Text, state
    assert_equal "An article about ACME Architects.", state.value
    assert_equal "An article about ACME Architects.", state.to_s
    assert_equal 33, state.length
    assert_predicate state, :frozen?
    assert_predicate state.value, :frozen?
  end

  def test_state_parse_rejects_blank_and_non_string_state
    ["", "   ", nil, 12, :text, { text: "hi" }, ["hi"]].each do |value|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI::Decisions::State.parse(value)
      end
      assert_equal "invalid_request", error.code
      assert_match(/state must be a(?: non-empty)? String/, error.message)
    end
  end

  def test_question_set_preserves_caller_keys_and_derives_wire_keys
    questions = RecordingStudioAI::Decisions::QuestionSet.parse(
      mentions_target: { type: :noul, instructions: "Does this mention the target?" },
      "coverage_type" => {
        type: :choice,
        instructions: "What type of coverage is this?",
        criteria: { feature: "A substantial feature", mention: nil }
      }
    )

    assert_equal 2, questions.length
    assert_equal([:mentions_target, "coverage_type"], questions.map { |entry| entry.key.public_key })
    assert_equal %w[mentions_target coverage_type], questions.canonical_keys
    assert_equal %i[noul choice], questions.types
    assert_equal "coverage_type", questions.fetch_canonical("coverage_type").key.canonical_key
    assert_nil questions.fetch_canonical("missing")
  end

  def test_question_set_rejects_keys_that_collide_after_normalization
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::QuestionSet.parse(
        risk: { type: :noul, instructions: "Symbol key" },
        "risk" => { type: :noul, instructions: "String key" }
      )
    end
    assert_match(/questions keys collide after normalization: risk/, error.message)
  end

  def test_question_set_rejects_empty_input_unknown_keys_and_unknown_types
    assert_match(/questions must be a non-empty Hash/, parse_questions_error({}))
    assert_match(/questions must be a non-empty Hash/, parse_questions_error(nil))
    assert_match(/questions must be a non-empty Hash/, parse_questions_error([]))
    assert_match(
      /questions\[verdict\] contains unknown keys: schema/,
      parse_questions_error(verdict: { type: :noul, instructions: "Fine", schema: {} })
    )
    assert_match(
      /questions\[verdict\]\.type must be one of: choice, score, noul/,
      parse_questions_error(verdict: { type: :vibes, instructions: "Fine" })
    )
    assert_match(
      /questions\[verdict\]\.type must be one of: choice, score, noul/,
      parse_questions_error(verdict: { instructions: "No type at all" })
    )
    assert_match(/questions\[verdict\] must be a Hash/, parse_questions_error(verdict: "noul"))
  end

  def test_question_instructions_must_be_a_non_empty_string
    ["", "   ", nil, 5].each do |instructions|
      assert_match(
        /question instructions must be a non-empty String/,
        parse_questions_error(verdict: { type: :noul, instructions: instructions })
      )
    end
  end

  def test_choice_criteria_accept_string_or_nil_descriptions_within_bounds
    question = RecordingStudioAI::Decisions::Choice.new(
      instructions: "Pick one.",
      criteria: { feature: "A substantial feature", "mention" => nil }
    )

    assert_equal :choice, question.type
    assert_equal %w[feature mention], question.canonical_keys
    assert_equal :feature, question.public_choice_for("feature")
    assert_equal "mention", question.public_choice_for("mention")
    assert_nil question.public_choice_for("unrelated")
    assert_equal "A substantial feature", question.criteria.first.description
    assert_nil question.criteria.last.description
    assert_predicate question, :frozen?
  end

  def test_choice_criteria_reject_bad_shapes_sizes_and_descriptions
    assert_match(/choice criteria must be a Hash/, choice_error([]))
    assert_match(/choice criteria must be a Hash/, choice_error(nil))
    assert_match(/choice criteria must contain between 1 and 255 entries/, choice_error({}))
    oversized = (1..256).to_h { |index| [:"criterion_#{index}", "Description"] }
    assert_match(/choice criteria must contain between 1 and 255 entries/, choice_error(oversized))
    assert_match(/choice criteria descriptions must be a non-empty String/, choice_error(feature: ""))
    assert_match(/choice criteria descriptions must be a non-empty String/, choice_error(feature: "  "))
    assert_match(/choice criteria descriptions must be a non-empty String/, choice_error(feature: 7))
    assert_match(/choice criteria keys must be a String or Symbol/, choice_error(1 => "Numeric key"))
    assert_match(
      /choice criteria keys collide after normalization: feature/,
      choice_error(:feature => "Symbol", "feature" => "String")
    )
  end

  def test_choice_accepts_exactly_255_criteria
    criteria = (1..255).to_h { |index| [:"criterion_#{index}", "Description"] }
    question = RecordingStudioAI::Decisions::Choice.new(instructions: "Pick one.", criteria: criteria)

    assert_equal 255, question.criteria.length
  end

  def test_score_criteria_are_an_ordered_list_of_two_to_ten_labels
    question = RecordingStudioAI::Decisions::Score.new(
      instructions: "How relevant?",
      criteria: ["Not relevant", "Weakly relevant", "Clearly relevant"]
    )

    assert_equal :score, question.type
    assert_equal ["Not relevant", "Weakly relevant", "Clearly relevant"], question.criteria
    assert_equal 2, question.maximum_score
    assert_predicate question, :frozen?
  end

  def test_score_criteria_reject_bad_shapes_sizes_and_labels
    assert_match(/score criteria must be an Array/, score_error({ low: "Low" }))
    assert_match(/score criteria must be an Array/, score_error(nil))
    assert_match(/score criteria must contain between 2 and 10 entries/, score_error(["Only one"]))
    assert_match(/score criteria must contain between 2 and 10 entries/, score_error([]))
    assert_match(/score criteria must contain between 2 and 10 entries/, score_error(Array.new(11, "Label")))
    assert_match(/score criteria must be a non-empty String/, score_error(["Low", ""]))
    assert_match(/score criteria must be a non-empty String/, score_error(["Low", 2]))
  end

  def test_noul_criteria_are_optional_and_must_be_exactly_true_and_false
    without = RecordingStudioAI::Decisions::Noul.new(instructions: "Is it on topic?")
    assert_equal :noul, without.type
    assert_nil without.criteria

    with = RecordingStudioAI::Decisions::Noul.new(
      instructions: "Is it on topic?",
      criteria: { true => "On topic", false => "Off topic" }
    )
    assert_equal({ true => "On topic", false => "Off topic" }, with.criteria)
    assert_predicate with, :frozen?
  end

  def test_noul_criteria_reject_other_key_sets_and_blank_descriptions
    assert_match(/noul criteria must be a Hash/, noul_error([]))
    assert_match(/noul criteria keys must be exactly true and false/, noul_error({ true => "Only true" }))
    assert_match(/noul criteria keys must be exactly true and false/, noul_error({ yes: "y", no: "n" }))
    assert_match(
      /noul criteria keys must be exactly true and false/,
      noul_error({ true => "y", false => "n", maybe: "m" })
    )
    assert_match(
      /noul criteria descriptions must be a non-empty String/,
      noul_error({ true => "", false => "Off topic" })
    )
    assert_match(
      /noul criteria keys must be exactly true and false/,
      noul_error({ "true" => "On topic", "false" => "Off topic" })
    )
  end

  def test_decision_input_is_capped
    assert_match(
      /state must be at most #{RecordingStudioAI::Decisions::MAXIMUM_STATE_CHARACTERS} characters/,
      decision_request_error(state: "a" * (RecordingStudioAI::Decisions::MAXIMUM_STATE_CHARACTERS + 1))
    )
    assert_match(
      /questions must contain at most #{RecordingStudioAI::Decisions::MAXIMUM_QUESTIONS} entries/,
      decision_request_error(questions: oversized_questions)
    )
    assert_match(/question instructions must be at most/, choice_error_for_long_instructions)
    assert_match(
      /decision input must be at most #{RecordingStudioAI::Decisions::MAXIMUM_DECISION_CHARACTERS} characters/,
      decision_request_error(
        state: "a" * RecordingStudioAI::Decisions::MAXIMUM_STATE_CHARACTERS,
        questions: budget_questions
      )
    )
  end

  def test_decision_question_limit_follows_configuration
    questions = 21.times.to_h { |index| ["q#{index}", { type: :noul, instructions: "Mentioned?" }] }
    RecordingStudioAI.configuration.maximum_decision_questions = 25

    request = decision_request(questions: questions)

    assert_equal 21, request.questions.length
  end

  def test_choice_answer_exposes_choice_probabilities_and_confidence
    answer = RecordingStudioAI::Decisions::ChoiceAnswer.new(
      choice: :feature, probabilities: { feature: 0.82, mention: 0.18 }, confidence: 0.91
    )

    assert_equal :choice, answer.type
    assert_equal :feature, answer.choice
    assert_equal({ feature: 0.82, mention: 0.18 }, answer.probabilities)
    assert_equal 0.91, answer.confidence
    assert_equal(
      { type: "choice", choice: :feature, probabilities: { feature: 0.82, mention: 0.18 }, confidence: 0.91 },
      answer.to_h
    )
    assert_predicate answer, :frozen?
  end

  def test_score_answer_keeps_the_string_indexes_the_provider_reports
    answer = RecordingStudioAI::Decisions::ScoreAnswer.new(
      score: 2.7, legend: { "0" => "Not relevant", "1" => "Weakly relevant" },
      probabilities: { "0" => 0.1, "1" => 0.9 }, confidence: 0.8
    )

    assert_equal :score, answer.type
    assert_equal 2.7, answer.score
    assert_equal({ "0" => "Not relevant", "1" => "Weakly relevant" }, answer.legend)
    assert_equal({ "0" => 0.1, "1" => 0.9 }, answer.probabilities)
    assert_equal 0.8, answer.confidence
  end

  def test_noul_answer_exposes_probability_and_no_confidence
    answer = RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.96)

    assert_equal :noul, answer.type
    assert_equal 0.96, answer.probability
    assert_equal({ type: "noul", probability: 0.96 }, answer.to_h)
    refute_respond_to answer, :confidence
    refute_respond_to answer, :probabilities
  end

  def test_answers_reject_probabilities_outside_zero_to_one_and_non_finite_scores
    [-0.01, 1.01, Float::INFINITY, Float::NAN, "0.5", nil].each do |probability|
      assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI::Decisions::NoulAnswer.new(probability: probability)
      end
    end

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::ScoreAnswer.new(
        score: Float::NAN, legend: { "0" => "Low" }, probabilities: { "0" => 1.0 }, confidence: 0.5
      )
    end
    assert_match(/score must be a finite number/, error.message)
  end

  def test_score_answer_rejects_non_string_legend_keys
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::ScoreAnswer.new(
        score: 1, legend: { 0 => "Low" }, probabilities: { "0" => 1.0 }, confidence: 0.5
      )
    end
    assert_match(/score legend keys must be Strings/, error.message)
  end

  def test_answer_set_is_addressable_by_the_original_question_key
    questions = RecordingStudioAI::Decisions::QuestionSet.parse(
      mentions_target: { type: :noul, instructions: "Mentioned?" },
      "coverage_type" => { type: :choice, instructions: "Which?", criteria: { feature: "Feature" } }
    )
    answers = RecordingStudioAI::Decisions::AnswerSet.from_canonical(
      question_set: questions,
      answers: {
        "mentions_target" => RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.96),
        "coverage_type" => RecordingStudioAI::Decisions::ChoiceAnswer.new(
          choice: :feature, probabilities: { feature: 1.0 }, confidence: 0.9
        )
      }
    )

    assert_equal 2, answers.length
    refute_predicate answers, :empty?
    assert_equal 0.96, answers[:mentions_target].probability
    assert_equal :feature, answers["coverage_type"].choice
    assert_equal 0.96, answers.fetch(:mentions_target).probability
    assert_nil answers["mentions_target"]
    assert_raises(KeyError) { answers.fetch("mentions_target") }
    assert_equal [:mentions_target, "coverage_type"], answers.to_h.keys
    assert_predicate answers, :frozen?
  end

  def test_answer_set_serializes_to_containment_safe_data
    questions = RecordingStudioAI::Decisions::QuestionSet.parse(
      relevance: { type: :score, instructions: "How relevant?", criteria: %w[Low High] }
    )
    answers = RecordingStudioAI::Decisions::AnswerSet.from_canonical(
      question_set: questions,
      answers: {
        "relevance" => RecordingStudioAI::Decisions::ScoreAnswer.new(
          score: 1, legend: { "0" => "Low", "1" => "High" },
          probabilities: { "0" => 0.2, "1" => 0.8 }, confidence: 0.75
        )
      }
    )

    assert_equal(
      {
        "relevance" => {
          "type" => "score", "score" => 1, "legend" => { "0" => "Low", "1" => "High" },
          "probabilities" => { "0" => 0.2, "1" => 0.8 }, "confidence" => 0.75
        }
      },
      answers.to_serializable_h
    )
  end

  def test_answer_set_requires_one_answer_of_the_requested_type_per_question
    questions = RecordingStudioAI::Decisions::QuestionSet.parse(
      verdict: { type: :noul, instructions: "Mentioned?" }
    )
    noul = RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.5)

    assert_match(/answers must be a Hash/, answer_set_error(questions, []))
    assert_match(/answers is missing verdict/, answer_set_error(questions, {}))
    assert_match(
      /answers contains unrequested keys: other/,
      answer_set_error(questions, { "verdict" => noul, "other" => noul })
    )
    assert_match(
      /answers\[verdict\] must be a NoulAnswer/,
      answer_set_error(questions, { "verdict" => RecordingStudioAI::Decisions::ChoiceAnswer.new(
        choice: :a, probabilities: { a: 1.0 }, confidence: 1.0
      ) })
    )
    assert_empty RecordingStudioAI::Decisions::AnswerSet.empty
  end

  def test_validate_decision_request_builds_a_typed_immutable_request
    request = RecordingStudioAI::Contracts::RequestValidation.validate_decision_request!(
      state: "Article body.",
      questions: {
        mentions_target: { type: :noul, instructions: "Mentioned?" },
        coverage_type: { type: :choice, instructions: "Which?", criteria: { feature: "Feature" } },
        relevance: { type: :score, instructions: "How relevant?", criteria: %w[Low High] }
      },
      profile: :high,
      purpose: "coverage_triage",
      root_recording: Actor.new(3),
      initiator: Actor.new(7),
      metadata: { feature: "pages" }
    )

    assert_instance_of RecordingStudioAI::Contracts::DecisionRequest, request
    assert_predicate request, :frozen?
    assert_instance_of RecordingStudioAI::Decisions::State::Text, request.state
    assert_instance_of RecordingStudioAI::Decisions::QuestionSet, request.questions
    assert_equal :high, request.profile
    assert_equal "coverage_triage", request.purpose
    assert_equal %i[noul choice score], request.questions.types
    assert_equal 13, request.input_character_count
    assert_equal 3, request.attribution.root_recording.id
    assert_equal 7, request.attribution.initiator.id
    assert_equal({ "feature" => "pages" }, request.metadata)
    assert_nil request.provider
    assert_nil request.model
    assert_nil request.fallbacks
    assert_nil request.execution_deadline
  end

  def test_validate_decision_request_defaults_the_profile_and_carries_a_deadline_forward
    request = decision_request(profile: nil)
    assert_equal RecordingStudioAI.configuration.default_profile, request.profile

    deadline = Time.now + 30
    with_deadline = request.with_execution_deadline(deadline)

    assert_equal deadline, with_deadline.execution_deadline
    assert_nil request.execution_deadline
    assert_equal request.questions, with_deadline.questions
    assert_equal request.state, with_deadline.state
  end

  def test_validate_decision_request_rejects_missing_and_blank_state
    assert_match(/state must be a String/, decision_request_error(state: nil))
    assert_match(/state must be a non-empty String/, decision_request_error(state: ""))
    assert_match(/state must be a non-empty String/, decision_request_error(state: "   "))
    assert_match(/state must be a String/, decision_request_error(state: { text: "hi" }))
  end

  def test_validate_decision_request_rejects_missing_and_malformed_questions
    assert_match(/questions must be a non-empty Hash/, decision_request_error(questions: nil))
    assert_match(/questions must be a non-empty Hash/, decision_request_error(questions: {}))
    assert_match(
      /questions\[verdict\]\.type must be one of/,
      decision_request_error(questions: { verdict: { type: :vibes, instructions: "Hm" } })
    )
    assert_match(
      /choice criteria must be a Hash/,
      decision_request_error(questions: { verdict: { type: :choice, instructions: "Hm", criteria: ["a"] } })
    )
    assert_match(
      /score criteria must contain between 2 and 10 entries/,
      decision_request_error(questions: { verdict: { type: :score, instructions: "Hm", criteria: ["a"] } })
    )
    assert_match(
      /noul criteria keys must be exactly true and false/,
      decision_request_error(questions: { verdict: { type: :noul, instructions: "Hm", criteria: { yes: "y" } } })
    )
  end

  def test_validate_decision_request_rejects_generation_options_as_unknown_keys
    {
      schema: { "type" => "object" },
      stream: true,
      prompt: "Summarize",
      messages: [{ role: "user", content: "hi" }],
      system_instruction: "Be concise",
      attachments: [],
      provider_native_tools: [:web_search],
      custom_tools: [],
      temperature: 0.5,
      verbosity: "low",
      max_output_tokens: 10,
      reasoning_effort: "high",
      prompt_definition: nil
    }.each do |key, value|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        decision_request(key => value)
      end
      assert_equal "invalid_request", error.code
      assert_equal "decision request contains unknown keys: #{key}", error.message
    end
  end

  def test_validate_decision_request_requires_attribution_and_a_known_profile
    assert_match(/root_recording is required/, decision_request_error(root_recording: nil))
    assert_match(/initiator is required/, decision_request_error(initiator: nil))
    assert_match(/profile must be one of: low, medium, high/, decision_request_error(profile: :turbo))
    assert_match(/purpose must be a machine-readable snake_case String/, decision_request_error(purpose: "Not Snake"))
  end

  def test_validate_decision_request_shares_fallback_rules_with_generation
    request = decision_request(fallbacks: [{ provider: :typesafe, model: "jev-latest" }])
    assert_equal [{ provider: :typesafe, model: "jev-latest" }], request.fallbacks

    assert_match(
      /fallbacks cannot be combined with provider or model/,
      decision_request_error(fallbacks: [{ provider: :typesafe, model: "jev-latest" }], provider: :typesafe)
    )
    assert_match(/model must be a non-empty String when provided/, decision_request_error(model: "  "))
  end

  def test_validate_decision_request_redacts_decision_payloads_from_metadata
    request = decision_request(metadata: {
                                 state: "raw state",
                                 questions: { verdict: "raw question" },
                                 instructions: "raw instructions",
                                 criteria: %w[raw criteria],
                                 feature: "pages"
                               })

    assert_equal(
      {
        "state" => "[REDACTED]", "questions" => "[REDACTED]", "instructions" => "[REDACTED]",
        "criteria" => "[REDACTED]", "feature" => "pages"
      },
      request.metadata
    )
  end

  def test_decision_request_rejects_untyped_state_and_questions
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::DecisionRequest.new(
        state: "raw string",
        questions: RecordingStudioAI::Decisions::QuestionSet.parse(v: { type: :noul, instructions: "Hm" }),
        profile: :medium,
        attribution: attribution
      )
    end

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::DecisionRequest.new(
        state: RecordingStudioAI::Decisions::State.parse("text"),
        questions: { v: { type: :noul, instructions: "Hm" } },
        profile: :medium,
        attribution: attribution
      )
    end
  end

  def test_decision_response_reports_the_decision_operation_and_serializes_answers
    questions = RecordingStudioAI::Decisions::QuestionSet.parse(
      verdict: { type: :noul, instructions: "Mentioned?" }
    )
    answers = RecordingStudioAI::Decisions::AnswerSet.from_canonical(
      question_set: questions,
      answers: { "verdict" => RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.42) }
    )
    response = RecordingStudioAI::Contracts::DecisionResponse.new(
      answers: answers, profile: :medium, provider: "typesafe", model: "jev-latest", attempts: []
    )

    assert_kind_of RecordingStudioAI::Contracts::Response, response
    assert_equal "decision", response.operation
    assert_predicate response, :success?
    assert_equal 0.42, response.answers[:verdict].probability
    assert_equal({ "verdict" => { "type" => "noul", "probability" => 0.42 } }, response.to_h.fetch(:answers))
    assert_nil response.served_model
    assert_nil response.to_h.fetch(:served_model)
    assert_includes RecordingStudioAI::Contracts::Response::OPERATIONS, "decision"

    reported = RecordingStudioAI::Contracts::DecisionResponse.new(
      answers: answers, profile: :medium, provider: "typesafe", model: "jev-latest",
      attempts: [], served_model: "jev-1.13.0"
    )
    assert_equal "jev-latest", reported.model
    assert_equal "jev-1.13.0", reported.served_model
    assert_equal "jev-1.13.0", reported.to_h.fetch(:served_model)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::DecisionResponse.new(
        answers: answers, profile: :medium, attempts: [], served_model: "  "
      )
    end
  end

  def test_decision_response_cannot_carry_answers_alongside_an_error
    questions = RecordingStudioAI::Decisions::QuestionSet.parse(
      verdict: { type: :noul, instructions: "Mentioned?" }
    )
    answers = RecordingStudioAI::Decisions::AnswerSet.from_canonical(
      question_set: questions,
      answers: { "verdict" => RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.42) }
    )

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::DecisionResponse.new(
        answers: answers, profile: :medium, attempts: [],
        error: RecordingStudioAI::Contracts::NormalizedError.new(
          category: "provider_error", code: "failed", message: "Failed", retryable: false, provider: "typesafe"
        )
      )
    end
    assert_match(/a failed decision response cannot carry answers/, error.message)
  end

  private

  def attribution
    RecordingStudioAI::Contracts::Attribution.new(root_recording: Actor.new(3), initiator: Actor.new(7))
  end

  def decision_request(**overrides)
    RecordingStudioAI::Contracts::RequestValidation.validate_decision_request!(
      state: "Article body.",
      questions: { verdict: { type: :noul, instructions: "Mentioned?" } },
      profile: :medium,
      root_recording: Actor.new(3),
      initiator: Actor.new(7),
      **overrides
    )
  end

  def decision_request_error(**overrides)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) { decision_request(**overrides) }.message
  end

  def parse_questions_error(questions)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::QuestionSet.parse(questions)
    end.message
  end

  def oversized_questions
    (RecordingStudioAI::Decisions::MAXIMUM_QUESTIONS + 1).times.to_h do |index|
      ["q#{index}", { type: :noul, instructions: "Mentioned?" }]
    end
  end

  def budget_questions
    6.times.to_h do |index|
      ["q#{index}", { type: :noul, instructions: "a" * RecordingStudioAI::Decisions::MAXIMUM_TEXT_CHARACTERS }]
    end
  end

  def choice_error_for_long_instructions
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::Choice.new(
        instructions: "a" * (RecordingStudioAI::Decisions::MAXIMUM_TEXT_CHARACTERS + 1),
        criteria: { feature: "Feature" }
      )
    end.message
  end

  def choice_error(criteria)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::Choice.new(instructions: "Pick one.", criteria: criteria)
    end.message
  end

  def score_error(criteria)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::Score.new(instructions: "How much?", criteria: criteria)
    end.message
  end

  def noul_error(criteria)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::Noul.new(instructions: "Is it?", criteria: criteria)
    end.message
  end

  def answer_set_error(questions, answers)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Decisions::AnswerSet.from_canonical(question_set: questions, answers: answers)
    end.message
  end
end
