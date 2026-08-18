# frozen_string_literal: true

class AIPlaygroundController < ApplicationController
  PROVIDERS = {
    "auto" => "Auto (profile default)",
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

  PLAYGROUND_SAMPLE_INPUTS = {
    "text" => "Osaka is warm, humid, and packed with street food this week."
  }.freeze

  def show
    setup_page_state
  end

  def create
    setup_page_state

    @form = default_form.merge(form_params.to_h)
    @request_id = SecureRandom.uuid
    sync_selected_model_state!
    @result_mode = batch_mode? ? "batch" : "generate"

    root_recording = playground_root_recording!

    if batch_mode?
      @response = execute_batch(root_recording: root_recording, request_id: @request_id)
    else
      @response = execute_generate(root_recording: root_recording, request_id: @request_id)
    end

    @response_payload = @response.to_h
    load_created_records!(@request_id)
    render_result
  rescue StandardError => error
    @error_message = playground_error_message(error)
    load_created_records!(@request_id)
    render_result(status: :unprocessable_entity)
  end

  private

  def render_result(status: :ok)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          result_frame_id,
          partial: "ai_playground/result",
          locals: result_locals(@result_mode)
        ), status: status
      end
      format.html { render :show, status: status }
    end
  end

  def result_frame_id(mode = @result_mode)
    mode == "batch" ? "batch_result" : "generate_result"
  end
  helper_method :result_frame_id

  # Results belong to the section that submitted them, so the other section
  # renders an empty frame instead of repeating the same payload.
  def result_locals(mode)
    return blank_result_locals(mode) unless @result_mode == mode

    {
      frame_id: result_frame_id(mode),
      error_message: @error_message,
      response_payload: @response_payload,
      request_id: @request_id,
      stream_text: @stream_text,
      stream_events: @stream_events,
      created_runs: @created_runs,
      created_attempts: @created_attempts
    }
  end
  helper_method :result_locals

  def blank_result_locals(mode)
    {
      frame_id: result_frame_id(mode),
      error_message: nil,
      response_payload: nil,
      request_id: nil,
      stream_text: nil,
      stream_events: [],
      created_runs: [],
      created_attempts: []
    }
  end

  def setup_page_state
    @provider_options = PROVIDERS.map { |value, label| { value: value, label: label } }
    @profile_options = PROFILES.map { |value, label| { value: value, label: label } }
    @form = default_form
    @tool_options = TOOL_CATALOG.map do |key, meta|
      { value: key, label: meta.fetch(:label), description: meta.fetch(:description) }
    end
    @prompt_options = registered_prompt_definitions.map do |definition|
      { value: prompt_identity(definition), label: prompt_option_label(definition) }
    end
    @prompt_previews = registered_prompt_definitions.to_h do |definition|
      [prompt_identity(definition), { preview: prompt_preview_text(definition) }]
    end
    @profile_candidates = profile_candidates_payload
    @model_definitions = model_definitions_payload
    sync_selected_model_state!
    @stream_events = []
    @stream_text = String.new
    @response_payload = nil
    @error_message = nil
    @created_runs = []
    @created_attempts = []
    @result_mode ||= nil
  end

  def sync_selected_model_state!
    candidates = candidates_for(@form.fetch("profile"), @form.fetch("provider"))
    selected = resolve_selected_candidate(candidates, @form["model"])
    @form["model"] = selected ? candidate_value(selected) : ""
    @selected_candidate = selected
    @selected_definition = selected && RecordingStudioAI.models.fetch(selected[:provider], selected[:model])
    @model_options = candidates.map do |candidate|
      {
        value: candidate_value(candidate),
        label: candidate_label(candidate)
      }
    end
    @selected_tool_key = selected_tool_key
    @selected_tool_description = TOOL_CATALOG.fetch(@selected_tool_key).fetch(:description)
    @selected_prompt_preview = prompt_preview_text(selected_prompt_definition)
  end

  def execute_generate(root_recording:, request_id:)
    kwargs = generation_kwargs(@form, root_recording: root_recording, request_id: request_id)
    if streaming_enabled?
      stream_result = RecordingStudioAI.generate(**kwargs.merge(stream: true)) do |event|
        @stream_events << event.to_h
        @stream_text << event.text_delta.to_s if event.respond_to?(:text_delta)
      end
      @stream_text = stream_result.text.to_s if @stream_text.blank?
      stream_result
    else
      RecordingStudioAI.generate(**kwargs)
    end
  end

  def execute_batch(root_recording:, request_id:)
    provider, model = split_candidate_value(@form["model"])
    RecordingStudioAI.submit_batch(
      **base_request_for(@form, root_recording: root_recording, request_id: request_id)
        .except(:purpose)
        .merge(
          provider: provider || provider_override(@form),
          model: model,
          items: batch_items_for(
            @form.fetch("batch_items", []),
            shared_prompt: @form.fetch("prompt", ""),
            web_search_enabled: web_search_enabled?
          )
        )
    )
  end

  def generation_kwargs(form, root_recording:, request_id:)
    definition = selected_prompt_definition(form)
    unless definition
      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "Pick a registered prompt before running generate.",
        code: "invalid_request"
      )
    end

    provider, model = split_candidate_value(form["model"])
    provider ||= provider_override(form)
    kwargs = base_request_for(form, root_recording: root_recording, request_id: request_id).merge(
      messages: definition.render(playground_prompt_inputs(definition)),
      prompt_definition: definition,
      provider: provider,
      model: model,
      provider_native_tools: web_search_enabled?(form) ? [ :web_search ] : [],
      custom_tools: generation_custom_tools(form, definition),
      attachments: attachments_for(form)
    )
    kwargs.merge(generation_parameters_for(form))
  end

  def generation_parameters_for(form)
    definition = definition_for_form(form)
    parameters = {
      temperature: present_number(form["temperature"]),
      verbosity: form["verbosity"].presence,
      max_output_tokens: present_integer(form["max_output_tokens"]),
      reasoning_effort: form["reasoning_effort"].presence
    }.compact

    return parameters unless definition

    parameters.select { |name, _value| definition.supports_parameter?(name) }
  end

  def definition_for_form(form)
    provider, model = split_candidate_value(form["model"])
    return nil unless provider && model

    RecordingStudioAI.models.fetch(provider, model)
  end

  def custom_tools_for(form)
    return [] unless form.fetch("use_custom_tool", "0") == "1"

    definition = definition_for_form(form)
    return [] if definition && !definition.supports_tool?(:custom_tools)

    key = selected_tool_key(form)
    [ { key: key, version: 1 } ]
  end

  def attachments_for(form)
    definition = definition_for_form(form)
    if definition
      input = definition.modalities[:input]
      return [] unless input.include?(:image) || input.include?(:file)
    end

    upload = form["attachment"].presence || params.dig(:ai_playground, :attachment)
    return [] unless upload.respond_to?(:read)

    data = read_capped_upload!(upload)
    content_type = upload.content_type.to_s
    type = content_type.start_with?("image/") ? :image : :file
    [
      {
        type: type,
        content_type: content_type,
        data: data,
        filename: upload.original_filename
      }
    ]
  end

  # Never trust client size headers alone. Reject claimed oversize first, then
  # read at most the configured limit (+1) so a lying Content-Length cannot DoS.
  def read_capped_upload!(upload)
    limit = attachment_byte_limit
    claimed = claimed_upload_bytes(upload)
    raise playground_file_too_big if claimed && claimed > limit

    io = upload_io(upload)
    io.rewind if io.respond_to?(:rewind)
    data = io.read(limit + 1).to_s
    raise playground_file_too_big if data.bytesize > limit

    data
  end

  def attachment_byte_limit
    [
      RecordingStudioAI.configuration.maximum_attachment_bytes,
      RecordingStudioAI.configuration.maximum_attachment_total_bytes
    ].min
  end

  def claimed_upload_bytes(upload)
    candidates = []
    candidates << upload.size if upload.respond_to?(:size) && !upload.size.nil?
    candidates << upload.tempfile.size if upload.respond_to?(:tempfile) && upload.tempfile
    candidates << request.content_length if request.content_length.present?
    values = candidates.compact.map(&:to_i)
    values.max
  end

  def upload_io(upload)
    return upload.tempfile if upload.respond_to?(:tempfile) && upload.tempfile

    upload
  end

  def playground_file_too_big
    RecordingStudioAI::Errors::ContractValidationError.new(
      "That file is too big for this playground.",
      code: "invalid_request"
    )
  end

  def playground_error_message(error)
    return error.message if error.is_a?(RecordingStudioAI::Errors::ContractValidationError)

    Rails.logger.error(
      "[ai_playground] #{error.class}: #{error.message}\n#{Array(error.backtrace).first(8).join("\n")}"
    )
    "That run didn't finish. Try again in a moment."
  end

  def base_request_for(form, root_recording:, request_id:)
    {
      root_recording: root_recording,
      initiator: current_user,
      initiator_kind: "user",
      execution_source: "web",
      profile: form.fetch("profile").to_sym,
      purpose: batch_mode?(form) ? "dummy_ai_playground_batch" : "dummy_ai_playground",
      request_id: request_id,
      metadata: {
        source: "dummy_ai_playground",
        mode: batch_mode?(form) ? "batch" : "generate"
      }
    }
  end

  def load_created_records!(request_id)
    return if request_id.blank?

    @created_runs = RecordingStudioAI::Run.where(request_id: request_id).order(created_at: :desc)
    @created_attempts = RecordingStudioAI::Attempt.joins(:run)
      .where(recording_studio_ai_runs: { request_id: request_id })
      .order(created_at: :desc)
  end

  def batch_items_for(prompts, shared_prompt: "", web_search_enabled: false)
    prompts = Array(prompts).map(&:to_s).map(&:strip).reject(&:blank?)
    prompts = [ default_form.fetch("prompt") ] if prompts.empty?

    prompts.each_with_index.map do |item_prompt, index|
      content = [ shared_prompt.to_s.strip, item_prompt ].reject(&:blank?).join("\n\n")
      {
        reference: "item-#{index + 1}",
        messages: [ user_message(content) ],
        purpose: "dummy_batch_call",
        provider_native_tools: web_search_enabled ? [ :web_search ] : []
      }
    end
  end

  def user_message(content)
    { role: "user", content: content }
  end

  def default_form
    medium_default = candidates_for("medium", "auto").first
    {
      "mode" => "generate",
      "provider" => "auto",
      "profile" => "medium",
      "model" => medium_default ? candidate_value(medium_default) : "",
      "prompt" => "what's the weather in Osaka",
      "prompt_key" => default_prompt_identity,
      "batch_items" => [
        "Summarize the latest weather conditions in Osaka.",
        "Summarize the latest weather conditions in Tokyo.",
        "Summarize the latest weather conditions in Kyoto."
      ],
      "web_search" => "0",
      "streaming" => "0",
      "use_custom_tool" => "0",
      "tool_key" => "dummy_echo_tool",
      "temperature" => "",
      "verbosity" => "",
      "max_output_tokens" => "",
      "reasoning_effort" => ""
    }
  end

  def profile_candidates_payload
    RecordingStudioAI.configuration.profiles.transform_keys(&:to_s).transform_values do |entries|
      Array(entries).map do |entry|
        attributes = entry.transform_keys(&:to_sym)
        {
          provider: attributes.fetch(:provider).to_s,
          model: attributes.fetch(:model).to_s,
          value: "#{attributes.fetch(:provider)}|#{attributes.fetch(:model)}",
          label: candidate_label(attributes)
        }
      end
    end
  end

  def model_definitions_payload
    RecordingStudioAI.models.all.to_h do |definition|
      [
        "#{definition.provider}|#{definition.model}",
        {
          provider: definition.provider.to_s,
          model: definition.model,
          display_name: definition.display_name,
          delivery: definition.delivery,
          parameters: definition.parameters,
          tools: definition.tools.map(&:to_s),
          modalities: {
            input: definition.modalities[:input].map(&:to_s),
            output: definition.modalities[:output].map(&:to_s)
          }
        }
      ]
    end
  end

  def candidates_for(profile, provider)
    provider = "" if provider.to_s == "auto"
    entries = Array(RecordingStudioAI.configuration.profiles[profile.to_sym]).map { |entry| entry.transform_keys(&:to_sym) }
    entries.select! { |entry| entry[:provider].to_s == provider.to_s } if provider.present?
    entries
  end

  def resolve_selected_candidate(candidates, value)
    return candidates.first if value.blank?

    provider, model = split_candidate_value(value)
    candidates.find { |candidate| candidate[:provider].to_s == provider.to_s && candidate[:model].to_s == model.to_s } ||
      candidates.first
  end

  def candidate_value(candidate)
    "#{candidate[:provider]}|#{candidate[:model]}"
  end

  def candidate_label(candidate)
    definition = RecordingStudioAI.models.fetch(candidate[:provider], candidate[:model])
    display = definition&.display_name || candidate[:model]
    "#{candidate[:provider].to_s.capitalize} · #{display}"
  end

  def split_candidate_value(value)
    return [ nil, nil ] if value.blank?

    provider, model = value.to_s.split("|", 2)
    return [ nil, nil ] if provider.blank? || model.blank?

    [ provider.to_sym, model ]
  end

  def selected_tool_key(form = @form)
    key = form.fetch("tool_key", default_form.fetch("tool_key")).to_s
    key = default_form.fetch("tool_key") unless TOOL_CATALOG.key?(key)
    key
  end

  def registered_prompt_definitions
    RecordingStudioAI.prompts.all
  end

  def prompt_identity(definition)
    "#{definition.namespace}:#{definition.key}:#{definition.version}"
  end

  def prompt_option_label(definition)
    "#{definition.name} · #{definition.namespace}.#{definition.key}"
  end

  def prompt_preview_text(definition)
    return "" unless definition

    definition.render(playground_prompt_inputs(definition)).map do |message|
      "#{message.fetch(:role).to_s.capitalize}\n#{message.fetch(:content)}"
    end.join("\n\n")
  end

  def playground_prompt_inputs(definition)
    definition.inputs.index_with { |name| PLAYGROUND_SAMPLE_INPUTS.fetch(name, "sample #{name}") }
  end

  def default_prompt_identity
    preferred = registered_prompt_definitions.find { |definition| definition.key == "analyze_text" }
    definition = preferred || registered_prompt_definitions.first
    definition ? prompt_identity(definition) : ""
  end

  def selected_prompt_definition(form = @form)
    identity = form.fetch("prompt_key", default_prompt_identity).to_s
    namespace, key, version = identity.split(":", 3)
    return registered_prompt_definitions.first if namespace.blank? || key.blank?

    RecordingStudioAI.prompts.fetch(namespace, key, version: version.present? ? version.to_i : nil) ||
      registered_prompt_definitions.first
  end

  def generation_custom_tools(form, definition)
    prompt_tools = definition.tools.filter_map do |tool|
      registered = RecordingStudioAI.tools.fetch(tool.fetch(:key), version: tool[:version])
      next unless registered

      { key: registered.key, version: registered.version }
    end

    (prompt_tools + custom_tools_for(form)).uniq
  end

  def web_search_enabled?(form = @form)
    form.fetch("web_search", "0") == "1"
  end

  def streaming_enabled?(form = @form)
    form.fetch("streaming", "0") == "1"
  end

  def batch_mode?(form = @form)
    form.fetch("mode", "generate") == "batch"
  end

  def provider_override(form = @form)
    value = form.fetch("provider", "auto").to_s
    return nil if value.blank? || value == "auto"

    value.to_sym
  end

  def present_number(value)
    return nil if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    value
  end

  def present_integer(value)
    return nil if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    value
  end

  def form_params
    params.require(:ai_playground).permit(
      :mode, :provider, :profile, :model, :prompt, :prompt_key, :web_search, :streaming, :use_custom_tool, :tool_key,
      :temperature, :verbosity, :max_output_tokens, :reasoning_effort, :attachment,
      batch_items: []
    )
  end

  # Never fall back to an arbitrary Workspace. Require an Accessible edit grant
  # on the currently selected root before spending provider credits.
  def playground_root_recording!
    root = current_root_recording
    if root.blank?
      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "Select a workspace you can access before running AI.",
        code: "authorization"
      )
    end

    unless RecordingStudioAccessible.authorized?(actor: current_user, recording: root, role: :edit)
      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "You need edit access on the selected workspace to run AI.",
        code: "authorization"
      )
    end

    root
  end
end
