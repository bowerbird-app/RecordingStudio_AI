# frozen_string_literal: true

require "test_helper"
require "cgi"
require "devise/test/integration_helpers"

class DecisionPlaygroundTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  README_STATE = "ACME Architects unveiled a waterfront library in Portland today. The firm designed the building, published drawings, and will oversee construction through 2028. The article is a substantial feature about the firm's design, not a passing mention."

  DECISION_BODY = {
    "model" => "jev-1.13.0",
    "answers" => {
      "mentions_target" => { "type" => "noul", "noul" => 0.96 },
      "described" => { "type" => "noul", "noul" => 0.99 },
      "coverage_type" => {
        "type" => "choice", "choice" => "feature",
        "probabilities" => { "feature" => 0.82, "mention" => 0.14, "unrelated" => 0.04 },
        "confidence" => 0.91
      },
      "relevance" => {
        "type" => "score", "score" => 2.7,
        "legend" => { "0" => "Not relevant", "1" => "Weakly relevant", "2" => "Clearly relevant", "3" => "Primarily about the target" },
        "probabilities" => { "0" => 0.05, "1" => 0.1, "2" => 0.3, "3" => 0.55 },
        "confidence" => 0.77
      }
    },
    "usage" => { "input_tokens" => 120, "output_tokens" => 8 }
  }.freeze

  class TypeSafeClient
    attr_reader :calls

    def initialize(body)
      @body = body
      @calls = []
    end

    def decide(model:, state:, questions:)
      @calls << { model: model, state: state, questions: questions }
      @body
    end
  end

  setup do
    @previous_typesafe_client = RecordingStudioAI.configuration.typesafe_client
    @user = User.create!(email: "decision-playground-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "Decision playground workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :edit)
    sign_in @user
    switch_to_root!(@root)
    @client = TypeSafeClient.new(DECISION_BODY)
    RecordingStudioAI.configuration.typesafe_client = @client
  end

  teardown do
    RecordingStudioAI.configuration.typesafe_client = @previous_typesafe_client
  end

  test "show renders the ACME seed and question keys" do
    get "/decision_playground"

    assert_response :success
    assert_includes CGI.unescapeHTML(response.body), README_STATE
    assert_select "input[name='decision_playground[questions][][key]'][value='mentions_target']"
    assert_select "input[name='decision_playground[questions][][key]'][value='described']"
    assert_select "input[name='decision_playground[questions][][key]'][value='coverage_type']"
    assert_select "input[name='decision_playground[questions][][key]'][value='relevance']"
  end

  test "create runs decide and ignores a blank extra question row" do
    post "/decision_playground", params: {
      decision_playground: {
        state: README_STATE,
        profile: "medium",
        model: "typesafe|jev-latest",
        questions: seeded_questions + [ { key: "", type: "noul", instructions: "", criteria_text: "" } ]
      }
    }

    assert_response :success
    assert_includes response.body, "0.96"
    assert_includes response.body, "0.99"
    assert_includes response.body, "feature"
    assert_includes response.body, "0.91"
    assert_includes response.body, "2.7"
    assert_includes response.body, "Not relevant"
    assert_equal "decision", RecordingStudioAI::Run.last.operation

    assert_equal 1, @client.calls.length
    questions = @client.calls.fetch(0).fetch(:questions)
    assert_equal 4, questions.length
    assert_equal(
      { "true" => "The firm is described as the designer", "false" => "The firm is not described as the designer" },
      questions.fetch("described").fetch(:criteria)
    )
  end

  test "unauthenticated visitors are redirected to sign in" do
    sign_out @user

    get "/decision_playground"

    assert_redirected_to new_user_session_path
  end

  private

  def seeded_questions
    [
      {
        key: "mentions_target",
        type: "noul",
        instructions: "Does this content substantially mention ACME Architects?",
        criteria_text: ""
      },
      {
        key: "described",
        type: "noul",
        instructions: "Is ACME Architects described as the designer of the library?",
        criteria_text: "true: The firm is described as the designer\nfalse: The firm is not described as the designer"
      },
      {
        key: "coverage_type",
        type: "choice",
        instructions: "What type of coverage is this?",
        criteria_text: "feature: A substantial feature about the target\nmention: A shorter mention\nunrelated: Not meaningfully about the target"
      },
      {
        key: "relevance",
        type: "score",
        instructions: "How relevant is this content to ACME Architects?",
        criteria_text: "Not relevant\nWeakly relevant\nClearly relevant\nPrimarily about the target"
      }
    ]
  end
end
