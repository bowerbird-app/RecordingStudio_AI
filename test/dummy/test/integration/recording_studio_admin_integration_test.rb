# frozen_string_literal: true

require "test_helper"

class RecordingStudioAdminIntegrationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(email: "admin-surface-#{SecureRandom.hex(4)}@example.com", password: "password123")
    workspace = Workspace.create!(name: "Admin surface workspace")
    @root_recording = RecordingStudio.root_recording_for(workspace)
    @original_access_recording_resolver = RecordingStudioAdmin.configuration.access_recording_resolver
    @original_required_access_role = RecordingStudioAdmin.configuration.required_access_role
    @original_access_management_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer
    RecordingStudioAdmin.configuration.access_recording_resolver = ->(_context) { @root_recording }
    RecordingStudioAdmin.configuration.required_access_role = :view
    RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }
  end

  teardown do
    RecordingStudioAdmin.configuration.access_recording_resolver = @original_access_recording_resolver
    RecordingStudioAdmin.configuration.required_access_role = @original_required_access_role
    RecordingStudioAccessible.configuration.access_management_authorizer = @original_access_management_authorizer
  end

  test "recording studio admin surface requires authentication" do
    get "/admin"

    assert_redirected_to new_user_session_path
  end

  test "recording studio admin surface includes recording studio ai section" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Recording Studio AI"
    refute_includes response.body, "href=\"/admin/screens/recording_studio_ai_overview\""
    refute_includes response.body, "href=\"/admin/screens/warnings\""
    refute_includes response.body, "/admin/screens/recording_studio_ai_overview?anchor_url="
    refute_includes response.body, "/admin/recording_studio_ai/admin"
    assert_includes response.body, "Close"
    assert_includes response.body, "href=\"/admin\""
    refute_includes response.body, "Recording tree"
    refute_includes response.body, "AI Admin"
  end

  test "methods guide documents the Recording Studio AI APIs" do
    authenticate_for_admin!

    get "/methods"

    assert_response :success
    assert_includes response.body, "Methods"
    assert_includes response.body, "RecordingStudioAI.generate"
    assert_includes response.body, "RecordingStudioAI.refresh_batch_async"
    assert_includes response.body, "RecordingStudioAI.models.register"
    assert_includes response.body, "RecordingStudioAI.models.fetch"
    assert_includes response.body, "href=\"/methods\""
  end

  test "config guide documents providers models and profiles" do
    authenticate_for_admin!

    get "/config"

    assert_response :success
    assert_includes response.body, "Add a Provider"
    assert_includes response.body, "Add a Model"
    assert_includes response.body, "Create Profiles"
    assert_includes response.body, "RecordingStudioAI.models.register"
    assert_includes response.body, "lib/recording_studio_ai/models/"
    assert_includes response.body, "delivery"
    assert_includes response.body, "modalities"
  end

  test "ai playground shows capability-driven generate form and batch section" do
    authenticate_for_admin!

    get "/ai_playground"

    assert_response :success
    assert_includes response.body, "Run generate"
    assert_includes response.body, "ai-playground-form"
    assert_includes response.body, "Auto (profile default)"
    assert_includes response.body, "name=\"ai_playground[model]\""
    assert_includes response.body, "Streaming"
    assert_includes response.body, "Web search"
    assert_includes response.body, "Live response"
    assert_equal 1, response.body.scan(/>Batch items</).size
    assert_equal 3, response.body.scan(/name="ai_playground\[batch_items\]\[\]"/).size
    refute_includes response.body, "ai-playground-stream#submit"
    assert_includes File.read(Rails.root.join("app/javascript/controllers/ai_playground_form_controller.js")),
                    "new FormData(event.currentTarget)"
  end

  test "ai calls table filters by status" do
    authenticate_for_admin!

    create_run!(status: "completed", operation: "generation")
    create_run!(status: "failed", operation: "generation")

    get "/admin/screens/ai_calls/table", params: { run_status: "failed" }

    assert_response :success
    assert_includes response.body, "run_status=failed"
    refute_includes response.body, ">Run<"
    assert_includes response.body, ">Failed<"
    refute_includes response.body, ">Completed<"
  end

  test "ai calls chart accepts a grouping filter" do
    authenticate_for_admin!
    create_run!(status: "completed", operation: "generation")

    get "/admin/screens/ai_calls/chart", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "AI calls trend"

    get "/admin/screens/ai_calls", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "group_by=month"
    assert_includes response.body, "controllers/recording_studio_admin/screen_filters_controller"
    assert_select "input[name='group_by']", count: 1
    assert_equal 1, response.body.scan(/name="run_status"/).size
  end

  test "ai calls defaults its date range to the last four weeks" do
    authenticate_for_admin!

    get "/admin/screens/ai_calls"

    assert_response :success
    assert_includes response.body, "value=\"last_4_weeks\""
    assert_includes response.body, "Tool key"
    refute_includes response.body, ">Short name<"
  end

  test "ai calls chart marks increased failed and cancelled runs as unfavorable" do
    authenticate_for_admin!

    %w[failed cancelled].each do |status|
      create_run!(status: status, operation: "generation")

      get "/admin/screens/ai_calls/chart", params: { run_status: status }

      assert_response :success
      assert_includes response.body, "+100%"
      assert_includes response.body, "text-[var(--color-danger-background-color)]"
    end
  end

  test "ai calls applies a custom date range" do
    authenticate_for_admin!

    included_run = create_run!(status: "completed", operation: "generation", resolved_model: "date-range-included")
    excluded_run = create_run!(status: "failed", operation: "generation", resolved_model: "date-range-excluded")
    included_run.update!(created_at: 2.days.ago)
    excluded_run.update!(created_at: 2.months.ago)

    get "/admin/screens/ai_calls/table", params: {
      date_range_start: 3.days.ago.to_date.iso8601,
      date_range_end: Date.current.iso8601
    }

    assert_response :success
    assert_includes response.body, included_run.resolved_model
    refute_includes response.body, excluded_run.resolved_model
  end

  test "errors failed calls widget links to failed ai calls" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/ai_calls?run_status=failed\""
  end

  test "tool calls widget links to tool calls screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/tool_calls\""
  end

  test "registered custom tools widget and section link to the tools screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Custom tools"
    refute_includes response.body, "Current registry"
    assert_includes response.body, "href=\"/admin/screens/registered_custom_tools\""
  end

  test "registered prompts widget and section link to the prompts screen" do
    authenticate_for_admin!
    create_run!(
      status: "completed",
      operation: "generation",
      prompt_namespace: "demo",
      prompt_key: "summarize_text",
      prompt_version: 1,
      prompt_name_snapshot: "Text Summary"
    )

    get "/admin"

    assert_response :success
    assert_includes response.body, "Registered prompts"
    assert_includes response.body, "Registered Prompts"
    assert_includes response.body, "href=\"/admin/screens/registered_prompts\""
    assert_includes response.body, "Text Summary"
    assert_includes response.body, "prompt=summarize_text"
    assert_includes response.body, "prompt_namespace=demo"
  end

  test "registered prompts screen shows chart and table metrics" do
    authenticate_for_admin!
    create_run!(
      status: "completed",
      operation: "generation",
      prompt_namespace: "demo",
      prompt_key: "summarize_text",
      prompt_version: 1,
      prompt_name_snapshot: "Text Summary",
      latency_ms: 420,
      input_tokens: 120,
      output_tokens: 80
    )
    create_run!(
      status: "failed",
      operation: "generation",
      prompt_namespace: "demo",
      prompt_key: "summarize_text",
      prompt_version: 1,
      prompt_name_snapshot: "Text Summary",
      latency_ms: 800,
      input_tokens: 200,
      output_tokens: 40
    )

    get "/admin/screens/registered_prompts"

    assert_response :success
    assert_includes response.body, "Registered prompts"
    assert_includes response.body, "Success rate"
    assert_includes response.body, "Error rate"
    assert_includes response.body, "Average duration"
    assert_includes response.body, "Avg input"
    assert_includes response.body, "Avg output"

    get "/admin/screens/registered_prompts/chart"

    assert_response :success
    assert_includes response.body, "Prompt call volume"
    assert_includes response.body, "Text Summary"
    assert_includes response.body, "Text Analysis"
    assert_includes response.body, "Osaka Weather"
    assert_includes response.body, "demo.analyze_text"
    assert_includes response.body, "demo.osaka_weather"
    assert_includes response.body, "demo.summarize_text"

    get "/admin/screens/registered_prompts/table"

    assert_response :success
    assert_includes response.body, "Text Summary"
    assert_includes response.body, "Avg input"
    assert_includes response.body, "Avg output"
    assert_includes response.body, ">160<"
    assert_includes response.body, ">60<"
    assert_includes response.body, "data-modal-id=\"registered-prompt-definition-demo-summarize_text-1\""
    assert_includes response.body, "Creates a concise summary of supplied text"
    assert_includes response.body, "Produce a concise factual summary."
    assert_includes response.body, "Summarize this text:"
    assert_includes response.body, "#000000"
  end

  test "registered prompts screen includes unused registered prompts" do
    authenticate_for_admin!
    unused_prompt_key = "unused_prompt_#{SecureRandom.hex(4)}"
    unused_prompt_name = "Unused Prompt #{unused_prompt_key}"
    RecordingStudioAI.prompts.register(
      owner: "dummy_app",
      namespace: :demo,
      key: unused_prompt_key.to_sym,
      version: 1,
      name: unused_prompt_name,
      short_name: "Unused",
      description: "An unused registered prompt for admin coverage.",
      inputs: [],
      messages: [{ role: :user, content: "Unused prompt content" }],
      defaults: { profile: :low, purpose: "unused_prompt" }
    )

    get "/admin/screens/registered_prompts/chart"

    assert_response :success
    assert_includes response.body, unused_prompt_name

    get "/admin/screens/registered_prompts/table"

    assert_response :success
    assert_includes response.body, unused_prompt_name

    unused_prompt_row = AdminScreens::RecordingStudioAIWidgets.prompt_rows(
      RecordingStudioAdmin::Context.new(
        params: {},
        current_actor: @user,
        controller: self
      )
    ).find { |row| row.key == unused_prompt_key }
    assert_equal 0, unused_prompt_row.calls
    assert_equal 0.0, unused_prompt_row.success_rate
    assert_equal 0.0, unused_prompt_row.error_rate
    assert_equal "No data", unused_prompt_row.average_duration
    assert_equal "No data", unused_prompt_row.average_input_tokens
    assert_equal "No data", unused_prompt_row.average_output_tokens
  end

  test "registered custom tools screen shows definition and execution metrics" do
    authenticate_for_admin!

    get "/admin/screens/registered_custom_tools"

    assert_response :success
    assert_includes response.body, "Registered custom tools"
    assert_includes response.body, "Cost class"
    assert_includes response.body, "Calls"
    refute_includes response.body, "Calls today"
    assert_includes response.body, "Success rate"
    assert_includes response.body, "Error rate"
    assert_includes response.body, "Average duration"
  end

  test "registered custom tools screen includes unused registered tools" do
    authenticate_for_admin!
    unused_tool_key = "unused_tool_#{SecureRandom.hex(4)}"
    unused_tool_name = "Unused Tool #{unused_tool_key}"
    RecordingStudioAI.tools.register(**DUMMY_TOOLS.first.merge(key: unused_tool_key, name: unused_tool_name))

    get "/admin/screens/registered_custom_tools/table"

    assert_response :success
    assert_includes response.body, unused_tool_name

    unused_tool_row = AdminScreens::RecordingStudioAIWidgets.custom_tool_rows(
      RecordingStudioAdmin::Context.new(
        params: {},
        current_actor: @user,
        controller: self
      )
    ).find { |row| row.key == unused_tool_key }
    assert_equal 0.0, unused_tool_row.success_rate
    assert_equal 0.0, unused_tool_row.error_rate
    assert_equal "No data", unused_tool_row.average_duration
  end

  test "registered custom tool opens its definition in a modal" do
    authenticate_for_admin!

    get "/admin/screens/registered_custom_tools/table"

    assert_response :success
    assert_includes response.body, "Dummy Echo Tool"
    assert_includes response.body, "<button"
    assert_includes response.body, "data-modal-id=\"custom-tool-definition-dummy_echo_tool-1\""
    assert_includes response.body, "data-controller=\"flat-pack--modal\""
    assert_includes response.body, "class=\"grid gap-4 text-sm\""
    refute_includes response.body, "md:grid-cols-2"
    assert_includes response.body, "#000000"
    assert_includes response.body, "Echoes input text with lightweight context metadata"
    refute_includes response.body, "Parameters"
    refute_includes response.body, "Repeated argument digests"

    get "/recording_studio_ai/admin/custom_tools/dummy_echo_tool/versions/1"

    assert_response :not_found
  end

  test "registered custom tools default reliability metrics to the last thirty days" do
    authenticate_for_admin!

    get "/admin/screens/registered_custom_tools"

    assert_response :success
    assert_includes response.body, "value=\"last_30_days\""
  end

  test "tool calls defaults its date range to the last thirty days" do
    authenticate_for_admin!

    get "/admin/screens/tool_calls"

    assert_response :success
    assert_includes response.body, "value=\"last_30_days\""
    filters = AdminScreens::RecordingStudioAIToolCallsScreen.filters
    assert_equal %i[date_range group_by tool_key], filters.first(3).map(&:key)
    assert_equal %i[run_id status prompt], filters.drop(3).map(&:key)
    assert_equal RecordingStudioAI::CustomToolInvocation::STATUSES.values,
           filters.find { |filter| filter.key == :status }.allowed_values
    assert_equal %i[created_at tool_key prompt status latency_ms],
                 AdminScreens::RecordingStudioAIToolCallsScreen.table.default_column_keys
    assert_includes AdminScreens::RecordingStudioAIToolCallsScreen.table.columns.map(&:key), :requires_confirmation
    assert_includes AdminScreens::RecordingStudioAIToolCallsScreen.table.columns.map(&:key), :read_only
    assert_includes AdminScreens::RecordingStudioAIToolCallsScreen.table.columns.map(&:key), :destructive
    assert_includes AdminScreens::RecordingStudioAIToolCallsScreen.table.columns.map(&:key), :error_code
    assert AdminScreens::RecordingStudioAIToolCallsScreen.table.show_columns_button?
    assert_equal "Unique identifier for this tool invocation.",
                 AdminScreens::RecordingStudioAIToolCallsScreen.table.columns.find { |column| column.key == :id }.header_tooltip
  end

  test "ai call tool-call count links to that run's tool calls" do
    authenticate_for_admin!
    selected_run = create_run!(status: "completed", operation: "generation")
    other_run = create_run!(status: "completed", operation: "generation")
    selected_run.custom_tool_invocations.create!(
      tool_key: "selected_tool",
      tool_version: 1,
      status: "completed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    other_run.custom_tool_invocations.create!(
      tool_key: "other_tool",
      tool_version: 1,
      status: "completed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    selected_run.update_column(:custom_tool_invocation_count, 1)
    other_run.update_column(:custom_tool_invocation_count, 1)

    get "/admin/screens/ai_calls/table"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/tool_calls?run_id=#{selected_run.id}\""

    get "/admin/screens/tool_calls/table", params: { run_id: selected_run.id }

    assert_response :success
    assert_includes response.body, "selected_tool"
    refute_includes response.body, "other_tool"
  end

  test "registered tool mini chart preserves the selected date range for matching ai calls" do
    authenticate_for_admin!
    RecordingStudioAI.tools.register(**DUMMY_TOOLS.first) unless RecordingStudioAI.tools.fetch("dummy_echo_tool", version: 1)
    matching_run = create_run!(status: "completed", operation: "generation", resolved_model: "matching-tool-run")
    other_run = create_run!(status: "completed", operation: "generation", resolved_model: "other-tool-run")
    matching_run.custom_tool_invocations.create!(tool_key: "dummy_echo_tool", tool_version: 1, status: "completed", read_only: true, destructive: false, requires_confirmation: false, idempotent: true)
    other_run.custom_tool_invocations.create!(tool_key: "other_tool", tool_version: 1, status: "completed", read_only: true, destructive: false, requires_confirmation: false, idempotent: true)

    start_date = 3.days.ago.to_date
    end_date = Date.current
    get "/admin/screens/registered_custom_tools/table", params: {
      start_date: start_date.iso8601,
      end_date: end_date.iso8601
    }

    assert_response :success
    assert_includes response.body, "flat-pack--chart-series-value"
    assert_includes response.body, "start_date=#{start_date.iso8601}"
    assert_includes response.body, "end_date=#{end_date.iso8601}"
    assert_includes response.body, "custom_tool_key=dummy_echo_tool"
    chart_payload = response.body.match(/custom_tool_key=dummy_echo_tool[^>]*>.*?data-flat-pack--chart-series-value="([^"]+)"/m).captures.first
    assert_equal 4, chart_payload.scan(/&quot;x&quot;/).size

    get "/admin/screens/ai_calls/table", params: {
      start_date: start_date.iso8601,
      end_date: end_date.iso8601,
      custom_tool_key: "dummy_echo_tool"
    }

    assert_response :success
    assert_includes response.body, "matching-tool-run"
    refute_includes response.body, "other-tool-run"
  end

  test "ai call attempt count links to attempts filtered and ordered by sequence" do
    authenticate_for_admin!
    selected_run = create_run!(status: "completed", operation: "generation")
    other_run = create_run!(status: "completed", operation: "generation")
    selected_run.attempts.create!(sequence: 2, kind: "retry", status: "completed", model: "selected-second")
    selected_run.attempts.create!(sequence: 1, kind: "primary", status: "failed", model: "selected-first")
    other_run.attempts.create!(sequence: 1, kind: "primary", status: "completed", model: "other-attempt")
    selected_run.update_column(:attempt_count, 2)
    other_run.update_column(:attempt_count, 1)

    get "/admin/screens/ai_calls/table"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/attempts?run_id=#{selected_run.id}\""

    get "/admin/screens/attempts/table", params: { run_id: selected_run.id }

    assert_response :success
    assert_includes response.body, "selected-first"
    assert_includes response.body, "selected-second"
    refute_includes response.body, "other-attempt"
    assert_operator response.body.index("selected-first"), :<, response.body.index("selected-second")
  end

  test "attempts defaults to four weeks and filters by provider and kind" do
    authenticate_for_admin!
    openai_run = create_run!(status: "completed", operation: "generation")
    google_run = create_run!(status: "completed", operation: "generation")
    openai_run.attempts.create!(sequence: 1, kind: "retry", status: "completed", provider: "openai", model: "attempt-openai-retry")
    google_run.attempts.create!(sequence: 1, kind: "primary", status: "completed", provider: "google", model: "attempt-google-primary")

    get "/admin/screens/attempts"

    assert_response :success
    assert_includes response.body, "value=\"last_4_weeks\""
    assert_includes response.body, "attempt_status"
    assert_includes response.body, "provider"
    assert_includes response.body, "name=\"group_by\""
    assert_includes response.body, "name=\"prompt\""
    assert_includes response.body, "name=\"model\""
    assert_includes response.body, "name=\"min_tokens\""
    assert_includes response.body, "name=\"max_tokens\""
    assert_includes response.body, "name=\"error_code\""

    get "/admin/screens/attempts/table", params: { provider: "openai", kind: "retry" }

    assert_response :success
    assert_includes response.body, "attempt-openai-retry"
    refute_includes response.body, "attempt-google-primary"
  end

  test "attempts table shows prompt and hides ai call sequence and kind by default" do
    authenticate_for_admin!
    run = create_run!(
      status: "completed",
      operation: "generation",
      prompt_key: "attempt-prompt",
      prompt_name_snapshot: "Attempt Prompt"
    )
    run.attempts.create!(
      sequence: 1,
      kind: "primary",
      status: "completed",
      provider: "openai",
      model: "attempt-prompt-model",
      total_tokens: 250,
      error_code: nil
    )

    get "/admin/screens/attempts/table"

    assert_response :success
    assert_includes response.body, "Attempt Prompt"
    assert_includes response.body, "Prompt"
    assert_select "th", text: /Created/
    assert_select "th", text: "Prompt"
    assert_select "th", text: "Status"
    assert_select "th", text: "AI call", count: 0
    assert_select "th", text: "Sequence", count: 0
    assert_select "th", text: "Kind", count: 0
  end

  test "attempts table filters by prompt model tokens and error code" do
    authenticate_for_admin!
    matching_run = create_run!(
      status: "completed",
      operation: "generation",
      prompt_key: "matching-attempt-prompt",
      prompt_name_snapshot: "Matching Attempt Prompt"
    )
    other_run = create_run!(
      status: "completed",
      operation: "generation",
      prompt_key: "other-attempt-prompt",
      prompt_name_snapshot: "Other Attempt Prompt"
    )
    matching_run.attempts.create!(
      sequence: 1,
      kind: "primary",
      status: "failed",
      provider: "openai",
      model: "matching-attempt-model",
      total_tokens: 500,
      error_code: "rate_limit"
    )
    other_run.attempts.create!(
      sequence: 1,
      kind: "primary",
      status: "completed",
      provider: "openai",
      model: "other-attempt-model",
      total_tokens: 50,
      error_code: "timeout"
    )

    get "/admin/screens/attempts/table", params: {
      prompt: "matching-attempt-prompt",
      model: "matching-attempt-model",
      min_tokens: 100,
      max_tokens: 1000,
      error_code: "rate_limit"
    }

    assert_response :success
    assert_includes response.body, "matching-attempt-model"
    assert_includes response.body, "Matching Attempt Prompt"
    refute_includes response.body, "other-attempt-model"
    refute_includes response.body, "Other Attempt Prompt"
  end

  test "attempts chart stacks volume by kind and accepts a grouping filter" do
    authenticate_for_admin!
    run = create_run!(status: "completed", operation: "generation")
    run.attempts.create!(sequence: 1, kind: "primary", status: "failed", provider: "openai", model: "attempt-chart-primary")
    run.attempts.create!(sequence: 2, kind: "retry", status: "completed", provider: "openai", model: "attempt-chart-retry")
    run.attempts.create!(sequence: 3, kind: "fallback", status: "completed", provider: "google", model: "attempt-chart-fallback")

    get "/admin/screens/attempts/chart", params: { group_by: "day" }

    assert_response :success
    assert_includes response.body, "Attempts by kind"
    assert_includes response.body, "Primary"
    assert_includes response.body, "Retry"
    assert_includes response.body, "Fallback"
    assert_includes response.body, "&quot;stacked&quot;:true"

    get "/admin/screens/attempts", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "group_by=month"
    assert_select "input[name='group_by']", count: 1
  end

  test "attempts chart includes zero-count days across the selected period" do
    authenticate_for_admin!
    run = create_run!(status: "cancelled", operation: "generation")
    start_date = 3.days.ago.to_date
    end_date = Date.current
    first_attempt = run.attempts.create!(
      sequence: 1,
      kind: "primary",
      status: "cancelled",
      provider: "openai",
      model: "attempt-chart-first-day"
    )
    last_attempt = run.attempts.create!(
      sequence: 2,
      kind: "primary",
      status: "cancelled",
      provider: "openai",
      model: "attempt-chart-last-day"
    )
    first_attempt.update_columns(created_at: start_date.noon, updated_at: start_date.noon)
    last_attempt.update_columns(created_at: end_date.noon, updated_at: end_date.noon)

    get "/admin/screens/attempts/chart", params: {
      start_date: start_date.iso8601,
      end_date: end_date.iso8601,
      group_by: "day",
      attempt_status: "cancelled"
    }

    assert_response :success
    chart_html = CGI.unescapeHTML(response.body)
    (start_date..end_date).each do |date|
      expected_count = [ start_date, end_date ].include?(date) ? 1 : 0
      assert_includes chart_html, %("x":"#{date.strftime('%b %-d')}","y":#{expected_count})
    end
  end

  test "attempts chart marks increased retries and failures as unfavorable" do
    authenticate_for_admin!
    run = create_run!(status: "completed", operation: "generation")
    run.attempts.create!(sequence: 1, kind: "retry", status: "failed", provider: "openai", model: "attempt-unfavorable")

    get "/admin/screens/attempts/chart", params: { kind: "retry" }

    assert_response :success
    assert_includes response.body, "+100%"
    assert_includes response.body, "text-[var(--color-danger-background-color)]"

    get "/admin/screens/attempts/chart", params: { attempt_status: "failed" }

    assert_response :success
    assert_includes response.body, "+100%"
    assert_includes response.body, "text-[var(--color-danger-background-color)]"
  end

  test "retry rate by model widget links to attempts" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Retry rate by model"
    assert_includes response.body, "href=\"/admin/screens/attempts\""
  end

  test "retry rate by model ranks the top three models by retried run share" do
    create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-100").update_column(:retry_count, 1)

    2.times.with_index do |index|
      create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-50").update_column(:retry_count, index.zero? ? 1 : 0)
    end
    4.times.with_index do |index|
      create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-25").update_column(:retry_count, index.zero? ? 1 : 0)
    end
    create_run!(status: "completed", operation: "generation", resolved_model: "retry-rate-0").update_column(:retry_count, 0)

    rows = AdminScreens::RecordingStudioAIWidgets.retry_rate_by_model_rows(
      RecordingStudioAI::Run.where(root_recording_id: @root_recording.id)
    )

    assert_equal [["retry-rate-100", 100.0], ["retry-rate-50", 50.0], ["retry-rate-25", 25.0]], rows
  end

  test "retry rate by model widget treats increased retries as unfavorable" do
    authenticate_for_admin!
    current_run = create_run!(status: "completed", operation: "generation", resolved_model: "retry-widget-current")
    previous_run = create_run!(status: "completed", operation: "generation", resolved_model: "retry-widget-previous")
    current_run.update_columns(retry_count: 2, created_at: 1.day.ago)
    previous_run.update_columns(retry_count: 1, created_at: 45.days.ago)

    get "/admin"

    assert_response :success
    assert_includes response.body, ">2<"
    assert_includes response.body, "+100%"
    assert_includes response.body, "text-[var(--color-danger-background-color)]"
  end

  test "tool calls table filters by status" do
    authenticate_for_admin!

    run = create_run!(status: "completed", operation: "generation")
    run.custom_tool_invocations.create!(
      tool_key: "completed_tool",
      tool_version: 1,
      status: "completed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )
    run.custom_tool_invocations.create!(
      tool_key: "failed_tool",
      tool_version: 1,
      status: "failed",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    )

    get "/admin/screens/tool_calls/table", params: { tool_status: "failed" }

    assert_response :success
    assert_includes response.body, "tool_status=failed"
    assert_includes response.body, "failed_tool"
    refute_includes response.body, "completed_tool"
  end

  test "tool calls table filters by prompt" do
    authenticate_for_admin!

    matching_run = create_run!(status: "completed", operation: "generation", prompt_key: "matching-prompt", prompt_name_snapshot: "Matching prompt")
    other_run = create_run!(status: "completed", operation: "generation", prompt_key: "other-prompt", prompt_name_snapshot: "Other prompt")
    matching_run.custom_tool_invocations.create!(tool_key: "matching_prompt_tool", tool_version: 1, status: "completed", read_only: true, destructive: false, requires_confirmation: false, idempotent: true)
    other_run.custom_tool_invocations.create!(tool_key: "other_prompt_tool", tool_version: 1, status: "completed", read_only: true, destructive: false, requires_confirmation: false, idempotent: true)

    get "/admin/screens/tool_calls/table", params: { prompt: "matching-prompt" }

    assert_response :success
    assert_includes response.body, "matching_prompt_tool"
    assert_includes response.body, "Matching prompt"
    refute_includes response.body, "other_prompt_tool"
    refute_includes response.body, "Other prompt"
  end

  test "tool calls chart accepts a grouping filter" do
    authenticate_for_admin!

    get "/admin/screens/tool_calls/chart", params: { group_by: "month" }

    assert_response :success
    assert_includes response.body, "Custom tool calls trend"
  end

  test "tool calls chart marks increased denied, failed, and rejected calls as unfavorable" do
    authenticate_for_admin!
    run = create_run!(status: "completed", operation: "generation")

    %w[denied failed rejected].each do |status|
      run.custom_tool_invocations.create!(
        tool_key: "#{status}_tool",
        tool_version: 1,
        status: status,
        read_only: true,
        destructive: false,
        requires_confirmation: false,
        idempotent: true
      )

      get "/admin/screens/tool_calls/chart", params: { tool_status: status }

      assert_response :success
      assert_includes response.body, "+100%"
      assert_includes response.body, "text-[var(--color-danger-background-color)]"
    end
  end

  test "estimated spend widget links to estimated spend screen" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "href=\"/admin/screens/estimated_spend\""
  end

  test "estimated spend defaults to the last four weeks grouped by day" do
    authenticate_for_admin!

    get "/admin/screens/estimated_spend"

    assert_response :success
    assert_select "input[value='Last 4 weeks']", minimum: 1
    filters = AdminScreens::RecordingStudioAIEstimatedSpendScreen.filters
    assert_includes filters.map(&:key), :prompt
    assert_equal %i[created_at prompt_name_snapshot status resolved_provider resolved_model total_tokens input_tokens output_tokens],
                 AdminScreens::RecordingStudioAIEstimatedSpendScreen.table.default_column_keys
    assert_includes AdminScreens::RecordingStudioAIEstimatedSpendScreen.table.columns.map(&:key), :id
  end

  test "estimated spend treats decreased token usage as favorable" do
    assert_equal :down, AdminScreens::RecordingStudioAIEstimatedSpendScreen.summary.change_good_when
  end

  test "estimated spend table filters by model" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "gpt-5",
      resolved_provider: "openai",
      total_tokens: 1200,
      input_tokens: 700,
      output_tokens: 500
    )
    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "gemini-2.5-pro",
      resolved_provider: "google",
      total_tokens: 900,
      input_tokens: 500,
      output_tokens: 400
    )

    get "/admin/screens/estimated_spend/table", params: { model: "gpt-5" }

    assert_response :success
    assert_includes response.body, "model=gpt-5"
    assert_includes response.body, "gpt-5"
    refute_includes response.body, "gemini-2.5-pro"
  end

  test "estimated spend table filters by status and token range" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "token-range-included",
      total_tokens: 1_500
    )
    create_run!(
      status: "failed",
      operation: "generation",
      resolved_model: "token-range-excluded-status",
      total_tokens: 1_500
    )
    create_run!(
      status: "completed",
      operation: "generation",
      resolved_model: "token-range-excluded-minimum",
      total_tokens: 500
    )

    get "/admin/screens/estimated_spend/table", params: {
      run_status: "completed",
      min_tokens: 1_000,
      max_tokens: 2_000
    }

    assert_response :success
    assert_includes response.body, "token-range-included"
    refute_includes response.body, "token-range-excluded-status"
    refute_includes response.body, "token-range-excluded-minimum"
  end

  test "estimated spend table filters by prompt" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      prompt_key: "included-spend-prompt",
      prompt_name_snapshot: "Included spend prompt",
      resolved_model: "included-spend-model",
      total_tokens: 1_500
    )
    create_run!(
      status: "completed",
      operation: "generation",
      prompt_key: "excluded-spend-prompt",
      prompt_name_snapshot: "Excluded spend prompt",
      resolved_model: "excluded-spend-model",
      total_tokens: 1_500
    )

    get "/admin/screens/estimated_spend/table", params: { prompt: "included-spend-prompt" }

    assert_response :success
    assert_includes response.body, "Included spend prompt"
    assert_includes response.body, "included-spend-model"
    refute_includes response.body, "Excluded spend prompt"
    refute_includes response.body, "excluded-spend-model"
  end

  test "ai calls p90 latency widget links to latency by model" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "AI Calls P90 Latency"
    assert_includes response.body, "href=\"/admin/screens/latency_by_model\""
  end

  test "prompt p90 latency widget links to latency by prompt" do
    authenticate_for_admin!

    get "/admin"

    assert_response :success
    assert_includes response.body, "Prompt P90 latency"
    assert_includes response.body, "href=\"/admin/screens/latency_by_prompt\""
  end

  test "p90 latency uses the nearest-rank percentile" do
    assert_equal 900, AdminScreens::RecordingStudioAIWidgets.percentile_latency([100, 200, 300, 400, 500, 600, 700, 800, 900, 10_000], percentile: 0.9)
    assert_equal 0, AdminScreens::RecordingStudioAIWidgets.percentile_latency([], percentile: 0.9)
  end

  test "latency by model shows grouped P90 latency" do
    authenticate_for_admin!

    [100, 200, 300, 400, 500, 600, 700, 800, 900, 10_000].each do |latency_ms|
      create_run!(status: "completed", operation: "generation", resolved_model: "p90-model", latency_ms: latency_ms)
    end

    get "/admin/screens/latency_by_model/table"

    assert_response :success
    assert_includes response.body, "p90-model"
    assert_includes response.body, ">900<"
    assert_includes response.body, "Median (ms)"
    assert_includes response.body, "Average (ms)"

    get "/admin/screens/latency_by_model/chart"

    assert_response :success
    assert_includes response.body, "Model P90 latency"
    assert_includes response.body, "P90 latency (ms)"
  end

  test "latency by prompt shows grouped P90 latency" do
    authenticate_for_admin!

    [100, 200, 300, 400, 500, 600, 700, 800, 900, 10_000].each do |latency_ms|
      create_run!(
        status: "completed",
        operation: "generation",
        prompt_key: "p90-prompt",
        prompt_name_snapshot: "P90 Prompt",
        latency_ms: latency_ms
      )
    end

    get "/admin/screens/latency_by_prompt/table"

    assert_response :success
    assert_includes response.body, "P90 Prompt"
    assert_includes response.body, ">900<"
    assert_includes response.body, "Median (ms)"

    get "/admin/screens/latency_by_prompt/chart"

    assert_response :success
    assert_includes response.body, "Prompt P90 latency"
    assert_includes response.body, "P90 latency (ms)"
  end

  test "warnings screen is not registered" do
    authenticate_for_admin!

    get "/admin/screens/warnings"

    assert_response :not_found
  end

  test "ai calls table slowest filter orders by latency descending" do
    authenticate_for_admin!

    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: 7011,
      resolved_model: "latency-model-7011"
    )
    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: 9011,
      resolved_model: "latency-model-9011"
    )
    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: 8011,
      resolved_model: "latency-model-8011"
    )
    create_run!(
      status: "completed",
      operation: "generation",
      latency_ms: nil,
      resolved_model: "latency-model-nil"
    )

    get "/admin/screens/ai_calls/table", params: { slowest: "1" }

    assert_response :success
    assert_includes response.body, "slowest=1"

    # Model names can also appear in filter option lists; only compare order inside the table body.
    table_body = response.body[/<tbody\b.*?>.*?<\/tbody>/m]
    assert table_body, "expected ai calls table body in response"

    index_9011 = table_body.index("latency-model-9011")
    index_8011 = table_body.index("latency-model-8011")
    index_7011 = table_body.index("latency-model-7011")
    index_nil = table_body.index("latency-model-nil")

    assert index_9011, "expected to find highest-latency model row in response"
    assert index_8011, "expected to find middle-latency model row in response"
    assert index_7011, "expected to find lowest-latency model row in response"
    assert_operator index_9011, :<, index_8011
    assert_operator index_8011, :<, index_7011
    assert_nil index_nil, "expected nil-latency rows to be excluded when slowest filter is enabled"
  end

  private

  def authenticate_for_admin!
    grant_result = RecordingStudioAccessible.grant_access(recording: @root_recording, actor: @user, role: :view)
    assert grant_result.success?, grant_result.error
    sign_in @user
    patch "/recording_studio_root_switchable/v1/root_switch", params: {
      scope: "all_workspaces",
      root_switch: {
        root_recording_id: @root_recording.id,
        return_to: "/"
      }
    }
    follow_redirect!
  end

  def create_run!(status:, operation:, prompt_key: nil, prompt_name_snapshot: nil, prompt_namespace: nil,
                  prompt_version: nil, resolved_model: nil, resolved_provider: nil,
                  total_tokens: nil, input_tokens: nil, output_tokens: nil, latency_ms: nil)
    RecordingStudioAI::Run.create!(
      operation: operation,
      status: status,
      prompt_namespace: prompt_namespace,
      prompt_key: prompt_key,
      prompt_version: prompt_version,
      prompt_name_snapshot: prompt_name_snapshot,
      resolved_model: resolved_model,
      resolved_provider: resolved_provider,
      latency_ms: latency_ms,
      root_recording_id: @root_recording.id,
      context_recording_id: @root_recording.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user",
      total_tokens: total_tokens,
      input_tokens: input_tokens,
      output_tokens: output_tokens
    )
  end
end
