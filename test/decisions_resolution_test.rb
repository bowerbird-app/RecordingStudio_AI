# frozen_string_literal: true

require "test_helper"

class DecisionsResolutionTest < RecordingStudioAI::Test::IsolatedCase
  Actor = Struct.new(:id)

  def setup
    @configuration = isolate_allow_all_configuration!
    @configuration.typesafe_api_key = "typesafe-test-key"
  end

  def test_capabilities_for_decision_requires_the_operation_and_only_the_requested_kinds
    assert_equal %i[decision decision_noul], capabilities_for(verdict: :noul)
    assert_equal %i[decision decision_choice], capabilities_for(coverage: :choice)
    assert_equal %i[decision decision_score], capabilities_for(relevance: :score)
    assert_equal(
      %i[decision decision_noul decision_choice decision_score],
      capabilities_for(verdict: :noul, coverage: :choice, relevance: :score)
    )
    assert_equal %i[decision decision_noul], capabilities_for(first: :noul, second: :noul)
  end

  def test_default_profiles_append_jev_after_the_generation_candidates
    %i[low medium high].each do |profile|
      entries = RecordingStudioAI::Configuration.new.profiles.fetch(profile)

      assert_equal({ provider: :typesafe, model: "jev-latest" }, entries.last)
      assert_equal(%i[openai gemini], entries[0..-2].map { |entry| entry.fetch(:provider) })
    end
  end

  def test_resolver_selects_the_decision_candidate_from_every_default_profile
    %i[low medium high].each do |profile|
      candidate = resolver.resolve(profile: profile, required_capabilities: %i[decision decision_choice])

      assert_equal :typesafe, candidate.provider
      assert_equal "jev-latest", candidate.model
      assert_equal %i[decision decision_choice decision_score decision_noul], candidate.capabilities
    end
  end

  def test_resolver_rejects_generation_only_candidates_for_a_decision
    @configuration.openai_api_key = "openai-test-key"
    @configuration.profiles[:medium] = [{ provider: :openai, model: "gpt-5" }]

    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      resolver.resolve(profile: :medium, required_capabilities: %i[decision decision_noul])
    end

    assert_equal "unsupported_capability", error.category
    assert_equal "unsupported_capability", error.code
    assert_match(/decision, decision_noul/, error.message)
  end

  def test_resolver_rejects_the_decision_model_for_a_generation
    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      resolver.resolve(profile: :medium, required_capabilities: %i[generation])
    end

    assert_equal "unsupported_capability", error.category
    assert_match(/generation/, error.message)
  end

  def test_resolver_rejects_a_decision_kind_the_model_does_not_declare
    @configuration.profiles[:medium] = [
      { provider: :typesafe, model: "jev-latest", capabilities: %i[decision decision_noul] }
    ]

    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      resolver.resolve(profile: :medium, required_capabilities: %i[decision decision_choice])
    end

    assert_equal "unsupported_capability", error.category
  end

  def test_planner_plans_the_decision_candidate_for_the_requested_profile
    plan = plan_decision(profile: :medium, questions: { coverage: :choice })

    assert_equal 1, plan.length
    assert_equal :typesafe, plan.first.candidate.provider
    assert_equal "jev-latest", plan.first.candidate.model
    assert_equal :medium, plan.first.profile
  end

  def test_planner_drops_a_repeated_decision_candidate_from_a_profile_fallback_chain
    @configuration.profile_fallbacks = { medium: %i[high low] }

    plan = plan_decision(profile: :medium, questions: { verdict: :noul })

    assert_equal 1, plan.length
    assert_equal([:typesafe], plan.map { |hop| hop.candidate.provider })
    assert_equal [:medium], plan.map(&:profile)
  end

  def test_generation_planning_drops_a_repeated_provider_and_model
    @configuration.openai_api_key = "openai-test-key"
    @configuration.profiles[:medium] = [{ provider: :openai, model: "gpt-5" }]
    @configuration.profiles[:high] = [{ provider: :openai, model: "gpt-5" }]
    @configuration.profile_fallbacks = { medium: [:high] }

    plan = planner.plan(
      { profile: :medium, attachments: [], provider_native_tools: [], custom_tools: [] },
      operation: :generation
    )

    assert_equal [:medium], plan.map(&:profile)
    assert_equal(["gpt-5"], plan.map { |hop| hop.candidate.model })
  end

  def test_planner_honours_a_pinned_decision_provider_and_model
    @configuration.allowed_provider_overrides = [:typesafe]

    plan = plan_decision(
      profile: :medium, questions: { verdict: :noul }, provider: :typesafe, model: "jev-latest"
    )

    assert_equal 1, plan.length
    assert_equal :typesafe, plan.first.candidate.provider
  end

  def test_planner_rejects_a_pinned_provider_that_is_not_an_allowed_override
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      plan_decision(profile: :medium, questions: { verdict: :noul }, provider: :typesafe, model: "jev-latest")
    end

    assert_equal "configuration", error.code
  end

  def test_planner_filters_explicit_fallbacks_by_decision_capability
    @configuration.openai_api_key = "openai-test-key"

    plan = plan_decision(
      profile: :medium,
      questions: { verdict: :noul },
      fallbacks: [
        { provider: :openai, model: "gpt-5" },
        { provider: :typesafe, model: "jev-latest" }
      ]
    )

    assert_equal 1, plan.length
    assert_equal :typesafe, plan.first.candidate.provider
  end

  def test_planner_rejects_explicit_fallbacks_without_any_decision_candidate
    @configuration.openai_api_key = "openai-test-key"

    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      plan_decision(
        profile: :medium, questions: { verdict: :noul },
        fallbacks: [{ provider: :openai, model: "gpt-5" }]
      )
    end

    assert_equal "unsupported_capability", error.category
  end

  def test_planner_refuses_to_plan_an_unknown_operation
    error = assert_raises(RecordingStudioAI::Providers::UnsupportedOperationError) do
      planner.plan({ profile: :medium }, operation: :divination)
    end

    assert_equal :divination, error.operation
    assert_nil error.provider
  end

  def test_unconfigured_typesafe_leaves_no_decision_candidate
    @configuration.typesafe_api_key = nil

    error = assert_raises(RecordingStudioAI::Errors::ResolutionError) do
      plan_decision(profile: :medium, questions: { verdict: :noul })
    end

    assert_equal "configuration", error.category
    assert_equal "not_implemented", error.code
  end

  def test_unconfigured_typesafe_does_not_change_generation_resolution
    @configuration.typesafe_api_key = nil
    @configuration.openai_api_key = "openai-test-key"

    candidate = resolver.resolve(profile: :medium, required_capabilities: %i[generation streaming])

    assert_equal :openai, candidate.provider
    assert_equal "gpt-5", candidate.model
  end

  def test_shipped_providers_install_typesafe_beside_openai_and_gemini
    assert_equal %i[openai gemini typesafe], RecordingStudioAI::Configuration.new.providers.keys
    assert_instance_of RecordingStudioAI::Providers::TypeSafe, @configuration.providers.fetch(:typesafe)
    assert_equal :typesafe, RecordingStudioAI::Providers::TypeSafe.provider_key
  end

  private

  def resolver
    RecordingStudioAI::Resolver.new(configuration: @configuration)
  end

  def planner
    RecordingStudioAI::Orchestration::Planner.new(configuration: @configuration)
  end

  def plan_decision(profile:, questions:, provider: nil, model: nil, fallbacks: nil)
    planner.plan(
      {
        profile: profile,
        provider: provider,
        model: model,
        fallbacks: fallbacks,
        questions: question_set(questions)
      },
      operation: :decision
    )
  end

  def capabilities_for(kinds)
    RecordingStudioAI::Capabilities.for_decision({ questions: question_set(kinds) })
  end

  def question_set(kinds)
    RecordingStudioAI::Decisions::QuestionSet.parse(
      kinds.transform_values { |type| question_attributes(type) }
    )
  end

  def question_attributes(type)
    case type
    when :choice then { type: :choice, instructions: "Which?", criteria: { feature: "Feature" } }
    when :score then { type: :score, instructions: "How much?", criteria: %w[Low High] }
    else { type: :noul, instructions: "Is it?" }
    end
  end
end
