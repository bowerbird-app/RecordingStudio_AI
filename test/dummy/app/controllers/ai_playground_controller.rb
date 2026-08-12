# frozen_string_literal: true

class AIPlaygroundController < ApplicationController
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

  def show
    setup_page_state
  end

  def create
    setup_page_state

    @form = default_form.merge(form_params.to_h)
    @request_id = SecureRandom.uuid

    root_recording = current_root_recording || RecordingStudio.root_recording_for(Workspace.order(:created_at).first)
    raise "No root recording is available for AI execution." if root_recording.nil?

    base_request = {
      root_recording: root_recording,
      initiator: current_user,
      initiator_kind: "user",
      execution_source: "web",
      profile: @form.fetch("profile").to_sym,
      purpose: "dummy_ai_playground",
      provider: provider_override,
      request_id: @request_id,
      metadata: {
        source: "dummy_ai_playground",
        capability: @form.fetch("capability")
      }
    }

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

  private

  def setup_page_state
    @provider_options = PROVIDERS.map { |value, label| { value: value, label: label } }
    @profile_options = PROFILES.map { |value, label| { value: value, label: label } }
    @form = default_form
    @stream_events = []
    @stream_text = ""
    @response_payload = nil
    @error_message = nil
    @created_runs = []
    @created_attempts = []
  end

  def execute_capability(base_request)
    capability = @form.fetch("capability")
    prompt = @form.fetch("prompt")
    web_search_enabled = web_search_enabled?

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
          messages: [user_message("#{prompt}\n\nCall dummy_echo_tool with the input field before answering.")],
          custom_tools: [
            {
              key: "dummy_echo_tool",
              version: 1
            }
          ]
        )
      )
    when "batch_calls"
      RecordingStudioAI.submit_batch(
        **base_request.merge(
          items: batch_items_for(prompt, web_search_enabled: web_search_enabled)
        )
      )
    else
      raise "Unsupported capability: #{capability}"
    end
  end

  def batch_items_for(prompt, web_search_enabled: false)
    [
      {
        reference: "item-1",
        messages: [user_message("#{prompt} (batch item 1)")],
        purpose: "dummy_batch_call",
        provider_native_tools: web_search_enabled ? [:web_search] : []
      },
      {
        reference: "item-2",
        messages: [user_message("#{prompt} (batch item 2)")],
        purpose: "dummy_batch_call",
        provider_native_tools: web_search_enabled ? [:web_search] : []
      },
      {
        reference: "item-3",
        messages: [user_message("#{prompt} (batch item 3)")],
        purpose: "dummy_batch_call",
        provider_native_tools: web_search_enabled ? [:web_search] : []
      }
    ]
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
      "web_search" => "0"
    }
  end

  def web_search_enabled?
    @form.fetch("web_search", "0") == "1"
  end

  def form_params
    params.require(:ai_playground).permit(:capability, :provider, :profile, :prompt, :web_search)
  end
end
