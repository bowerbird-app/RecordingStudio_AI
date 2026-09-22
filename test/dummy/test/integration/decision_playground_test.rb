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

  setup do
    @previous_typesafe_client = RecordingStudioAI.configuration.typesafe_client
    @previous_typesafe_api_key = RecordingStudioAI.configuration.typesafe_api_key
    RecordingStudioAI.configuration.typesafe_client = nil
    RecordingStudioAI.configuration.typesafe_api_key = "playground-test-key"
    @captured_requests = []
    @user = User.create!(email: "decision-playground-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    workspace = Workspace.create!(name: "Decision playground workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @root, actor: @user, role: :edit)
    sign_in @user
    switch_to_root!(@root)
  end

  teardown do
    RecordingStudioAI.configuration.typesafe_client = @previous_typesafe_client
    RecordingStudioAI.configuration.typesafe_api_key = @previous_typesafe_api_key
  end

  test "show renders the ACME seed and question keys" do
    get "/decision_playground"

    assert_response :success
    assert_includes CGI.unescapeHTML(response.body), README_STATE
    assert_select "input[name='decision_playground[questions][][key]'][value='mentions_target']"
    assert_select "input[name='decision_playground[questions][][key]'][value='described']"
    assert_select "input[name='decision_playground[questions][][key]'][value='coverage_type']"
    assert_select "input[name='decision_playground[questions][][key]'][value='relevance']"
    assert_select "#decision_result"
    assert_includes response.body, "md:grid-cols-2"
    assert_select "form[data-turbo=false]", count: 0
  end

  test "create runs decide through the TypeSafe client and ignores a blank extra question row" do
    with_typesafe_http do
      post "/decision_playground", params: {
        decision_playground: {
          state: README_STATE,
          profile: "medium",
          model: "typesafe|jev-latest",
          questions: seeded_questions + [ { key: "", type: "noul", instructions: "", criteria_text: "" } ]
        }
      }
    end

    assert_response :success
    assert_includes response.body, "Served model: jev-1.13.0"
    assert_includes response.body, "0.96"
    assert_includes response.body, "0.99"
    assert_includes response.body, "feature"
    assert_includes response.body, "0.91"
    assert_includes response.body, "2.7"
    assert_includes response.body, "Not relevant"
    assert_equal "decision", RecordingStudioAI::Run.last.operation

    assert_equal 1, @captured_requests.length
    request = @captured_requests.fetch(0)
    assert_equal "/v1/systemone", request.path
    assert_equal "Bearer playground-test-key", request["Authorization"]
    body = JSON.parse(request.body)
    questions = body.fetch("questions")
    assert_equal 4, questions.length
    assert_equal(
      { "true" => "The firm is described as the designer", "false" => "The firm is not described as the designer" },
      questions.fetch("described").fetch("criteria")
    )
  end

  test "choice criteria round trip keys that contain a colon" do
    criteria = { "a:b" => "has: colon", "plain" => nil, "slash\\key" => "kept" }
    loaded = DecisionPlayground::CriteriaCodec.load("choice", DecisionPlayground::CriteriaCodec.dump("choice", criteria))

    assert_equal criteria, loaded
  end

  test "create lets the gem reject a viewer on the selected workspace" do
    viewer = User.create!(email: "decision-viewer-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
    grant_accessible!(recording: @root, actor: viewer, role: :view)
    sign_in viewer
    switch_to_root!(@root)

    assert_no_difference -> { RecordingStudioAI::Run.count } do
      post "/decision_playground", params: {
        decision_playground: {
          state: README_STATE,
          profile: "medium",
          model: "typesafe|jev-latest",
          questions: seeded_questions
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "recording_studio_ai.execute"
    assert_empty @captured_requests
  end

  test "create refreshes the results column with turbo and leaves the form in place" do
    with_typesafe_http do
      post "/decision_playground",
        params: {
          decision_playground: {
            state: README_STATE,
            profile: "medium",
            model: "typesafe|jev-latest",
            questions: seeded_questions
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/action="replace" target="decision_result"/, response.body)
    assert_includes response.body, "0.96"
    assert_includes response.body, "feature"
    refute_includes response.body, 'name="decision_playground[state]"'
  end

  test "unauthenticated visitors are redirected to sign in" do
    sign_out @user

    get "/decision_playground"

    assert_redirected_to new_user_session_path
  end

  private

  def with_typesafe_http
    http_response = Net::HTTPOK.new("1.1", "200", "OK")
    http_response.instance_variable_set(:@read, true)
    http_response.instance_variable_set(:@body, JSON.generate(DECISION_BODY))
    http = Object.new
    captured = @captured_requests
    http.define_singleton_method(:request) do |request|
      captured << request
      http_response
    end
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) do |*_args, **_kwargs, &block|
      block.call(http)
    end
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

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
