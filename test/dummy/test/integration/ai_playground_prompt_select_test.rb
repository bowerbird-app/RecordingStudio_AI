# frozen_string_literal: true

require "test_helper"

class AIPlaygroundPromptSelectTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "playground generate form lists registered prompts and a disabled preview" do
    user = User.create!(email: "playground-prompts-#{SecureRandom.hex(4)}@example.com", password: "password123")
    Workspace.create!(name: "Prompt list workspace")
    sign_in user

    get "/ai_playground"

    assert_response :success
    assert_includes response.body, "name=\"ai_playground[prompt_key]\""
    assert_includes response.body, "demo:analyze_text:1"
    assert_includes response.body, "demo:osaka_weather:1"
    assert_includes response.body, "demo:summarize_text:1"
    assert_includes response.body, "Use the available tools to inspect the supplied text"
    assert_includes response.body, "Osaka is warm, humid, and packed with street food this week."
    assert_select "textarea[name='ai_playground[prompt_preview]'][disabled]"
    assert_select "textarea[name='ai_playground[prompt]']", count: 1
    assert_includes response.body, "name=\"ai_playground[use_custom_tool]\""
    assert_includes response.body, "name=\"ai_playground[tool_key]\""
    assert_includes response.body, "Dummy Echo Tool"
    assert_includes response.body, "Dummy Keyword Tool"
    assert_includes response.body, "Dummy Summary Tool"
  end

  test "generate sends the selected registered prompt and its tools" do
    captured = post_generate!("demo:analyze_text:1")

    assert_equal "analyze_text", captured[:prompt_definition].key
    assert_includes captured[:custom_tools], { key: "dummy_echo_tool", version: 1 }
    assert_includes captured[:custom_tools], { key: "dummy_keyword_tool", version: 1 }
    assert captured[:messages].any? { |message| message[:content].include?("Analyze this text") }
    assert captured[:messages].any? { |message| message[:content].include?("Osaka is warm") }
  end

  test "the playground custom tool is sent with the selected prompt" do
    captured = post_generate!(
      "demo:osaka_weather:1",
      extra: { use_custom_tool: "1", tool_key: "dummy_echo_tool" }
    )

    assert_equal "osaka_weather", captured[:prompt_definition].key
    assert_equal [{ key: "dummy_echo_tool", version: 1 }], captured[:custom_tools]
    assert captured[:messages].any? { |message| message[:content].include?("What's the weather in Osaka?") }
  end

  test "the playground custom tool is added on top of the prompt's tools" do
    captured = post_generate!(
      "demo:analyze_text:1",
      extra: { use_custom_tool: "1", tool_key: "dummy_summary_tool" }
    )

    assert_equal "analyze_text", captured[:prompt_definition].key
    assert_includes captured[:custom_tools], { key: "dummy_echo_tool", version: 1 }
    assert_includes captured[:custom_tools], { key: "dummy_keyword_tool", version: 1 }
    assert_includes captured[:custom_tools], { key: "dummy_summary_tool", version: 1 }
  end

  private

  def post_generate!(prompt_key, extra: {})
    user = User.create!(email: "playground-prompt-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Prompt run workspace")
    root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: root, actor: user, role: :edit)
    sign_in user
    switch_to_root!(root)

    captured = nil
    singleton = RecordingStudioAI.singleton_class
    original = singleton.instance_method(:generate)
    singleton.define_method(:generate) do |**kwargs|
      captured = kwargs
      response = Object.new
      response.define_singleton_method(:to_h) do
        { success: true, operation: "generation", attempts: [] }
      end
      response
    end

    post "/ai_playground", params: {
      ai_playground: {
        mode: "generate",
        prompt_key: prompt_key,
        profile: "medium",
        provider: "auto"
      }.merge(extra)
    }

    assert_response :success
    captured
  ensure
    RecordingStudioAI.singleton_class.define_method(:generate, original) if original
  end
end
