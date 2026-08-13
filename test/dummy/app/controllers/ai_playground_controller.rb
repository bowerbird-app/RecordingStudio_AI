# frozen_string_literal: true

class AIPlaygroundController < ApplicationController
  include ActionController::Live

  CAPABILITIES = {
    "chat" => "Chat",
    "streaming" => "Streaming",
    "tool_calls" => "Tool Calls",
    "batch_calls" => "Batch"
  }.freeze

  PROVIDERS = {
    "" => "Auto (profile default)",
    "openai" => "OpenAI",
    "gemini" => "Gemini"
  }.freeze

  PROFILES = {
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High"
  }.freeze

  TOOL_CATALOG = {
    "dummy_echo_tool" => {
      label: "Dummy Echo Tool",
      description: "Echoes the prompt text and returns run metadata. Useful for validating the end-to-end tool-call loop."
    },
    "dummy_summary_tool" => {
      label: "Dummy Summary Tool",
      description: "Produces a short preview summary with truncation metadata for quick summarization demos."
    },
    "dummy_keyword_tool" => {
      label: "Dummy Keyword Tool",
      description: "Extracts simple keyword candidates from the prompt for classification/tagging demos."
    }
  }.freeze

  def show
    setup_page_state
  end

  def create
    setup_page_state

    @form = default_form.merge(form_params.to_h)
    @request_id = SecureRandom.uuid

    root_recording = current_root_recording || RecordingStudio.root_recording_for(Workspace.order(:created_at).first)
    raise "No root recording is available for AI execution." if root_recording.nil?

    base_request = base_request_for(@form, root_recording: root_recording, request_id: @request_id)

    @response = execute_capability(base_request)
    @response_payload = @response.to_h
    @created_runs = RecordingStudioAI::Run.where(request_id: @request_id).order(created_at: :desc)
    @created_attempts = RecordingStudioAI::Attempt.joins(:run)
      .where(recording_studio_ai_runs: { request_id: @request_id })
      .order(created_at: :desc)

    render :show
  rescue StandardError => error
    @error_message = "#{error.class}: #{error.message}"
    @created_runs = RecordingStudioAI::Run.where(request_id: @request_id).order(created_at: :desc)
    @created_attempts = RecordingStudioAI::Attempt.joins(:run)
      .where(recording_studio_ai_runs: { request_id: @request_id })
      .order(created_at: :desc)
    render :show, status: :unprocessable_entity
  end

  def stream
    form = default_form.merge(form_params.to_h).merge("capability" => "streaming")
    request_id = SecureRandom.uuid
    root_recording = current_root_recording || RecordingStudio.root_recording_for(Workspace.order(:created_at).first)
    raise "No root recording is available for AI execution." if root_recording.nil?

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"
    response.headers["Last-Modified"] = Time.current.httpdate
    write_stream_event(type: "started", request_id: request_id)

    RecordingStudioAI.stream(
      **base_request_for(form, root_recording: root_recording, request_id: request_id).merge(
        messages: [user_message(form.fetch("prompt"))],
        provider_native_tools: form.fetch("web_search", "0") == "1" ? [:web_search] : []
      )
    ) do |event|
      text = event.text_delta.to_s if event.respond_to?(:text_delta)
      write_stream_event(type: "delta", text: text) if text.present?
    end
    write_stream_event(type: "complete")
  rescue StandardError => error
    write_stream_event(type: "error", message: "#{error.class}: #{error.message}")
  ensure
    response.stream.close
  end

  private

  def base_request_for(form, root_recording:, request_id:)
    {
      root_recording: root_recording,
      initiator: current_user,
      initiator_kind: "user",
      execution_source: "web",
      profile: form.fetch("profile").to_sym,
      purpose: "dummy_ai_playground",
      provider: form.fetch("provider").present? ? form.fetch("provider").to_sym : nil,
      request_id: request_id,
      metadata: {
        source: "dummy_ai_playground",
        capability: form.fetch("capability")
      }
    }
  end

  def write_stream_event(payload)
    response.stream.write("data: #{JSON.generate(payload)}\n\n")
  end

  def setup_page_state
    @provider_options = PROVIDERS.map { |value, label| { value: value, label: label } }
    @profile_options = PROFILES.map { |value, label| { value: value, label: label } }
    @form = default_form
    @tool_options = TOOL_CATALOG.map do |key, meta|
      { value: key, label: meta.fetch(:label), description: meta.fetch(:description) }
    end
    @selected_tool_key = default_form.fetch("tool_key")
    @selected_tool_description = TOOL_CATALOG.fetch(@selected_tool_key).fetch(:description)
    @stream_events = []
    @stream_text = String.new
    @response_payload = nil
    @error_message = nil
    @created_runs = []
    @created_attempts = []
  end

  def execute_capability(base_request)
    capability = @form.fetch("capability")
    prompt = @form.fetch("prompt")
    web_search_enabled = web_search_enabled?
    tool_key = selected_tool_key

    case capability
    when "chat"
      RecordingStudioAI.generate(
        **base_request.merge(
          messages: [user_message(prompt)],
          provider_native_tools: web_search_enabled ? [:web_search] : []
        )
      )
    when "streaming"
      stream_result = RecordingStudioAI.stream(
        **base_request.merge(
          messages: [user_message(prompt)],
          provider_native_tools: web_search_enabled ? [:web_search] : []
        )
      ) do |event|
        @stream_events << event.to_h
        @stream_text << event.text_delta.to_s if event.respond_to?(:text_delta)
      end
      @stream_text = stream_result.text.to_s if @stream_text.blank?
      stream_result
    when "tool_calls"
      RecordingStudioAI.generate(
        **base_request.merge(
          messages: [user_message(tool_call_prompt(prompt: prompt, tool_key: tool_key))],
          custom_tools: [
            {
              key: tool_key,
              version: 1
            }
          ]
        )
      )
    when "batch_calls"
      RecordingStudioAI.submit_batch(
        **base_request.except(:purpose).merge(
          items: batch_items_for(
            @form.fetch("batch_items", []),
            shared_prompt: @form.fetch("prompt", ""),
            web_search_enabled: web_search_enabled
          )
        )
      )
    else
      raise "Unsupported capability: #{capability}"
    end
  end

  def batch_items_for(prompts, shared_prompt: "", web_search_enabled: false)
    prompts = Array(prompts).map(&:to_s).map(&:strip).reject(&:blank?)
    prompts = [default_form.fetch("prompt")] if prompts.empty?

    prompts.each_with_index.map do |item_prompt, index|
      content = [shared_prompt.to_s.strip, item_prompt].reject(&:blank?).join("\n\n")
      {
        reference: "item-#{index + 1}",
        messages: [user_message(content)],
        purpose: "dummy_batch_call",
        provider_native_tools: web_search_enabled ? [:web_search] : []
      }
    end
  end

  def user_message(content)
    { role: "user", content: content }
  end

  def provider_override
    value = @form.fetch("provider")
    value.present? ? value.to_sym : nil
  end

  def default_form
    {
      "capability" => "chat",
      "provider" => "",
      "profile" => "medium",
      "prompt" => "what's the weather in Osaka",
      "batch_items" => [
        "Summarize the latest weather conditions in Osaka.",
        "Summarize the latest weather conditions in Tokyo.",
        "Summarize the latest weather conditions in Kyoto."
      ],
      "web_search" => "0",
      "tool_key" => "dummy_echo_tool"
    }
  end

  def selected_tool_key
    key = @form.fetch("tool_key", default_form.fetch("tool_key")).to_s
    key = default_form.fetch("tool_key") unless TOOL_CATALOG.key?(key)

    @selected_tool_key = key
    @selected_tool_description = TOOL_CATALOG.fetch(key).fetch(:description)
    key
  end

  def tool_call_prompt(prompt:, tool_key:)
    "#{prompt}\n\nCall #{tool_key} with the input field before answering."
  end

  def web_search_enabled?
    @form.fetch("web_search", "0") == "1"
  end

  def form_params
    params.require(:ai_playground).permit(:capability, :provider, :profile, :prompt, :web_search, :tool_key, batch_items: [])
  end
end
