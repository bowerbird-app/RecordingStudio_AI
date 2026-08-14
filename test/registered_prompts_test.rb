# frozen_string_literal: true

require "test_helper"

class RegisteredPromptsTest < Minitest::Test
  def setup
    @original_prompts = RecordingStudioAI.instance_variable_get(:@prompts)
    @original_tools = RecordingStudioAI.instance_variable_get(:@tools)
    RecordingStudioAI.instance_variable_set(:@prompts, RecordingStudioAI::Prompts::Registry.new)
    RecordingStudioAI.instance_variable_set(:@tools, RecordingStudioAI::Tools::Registry.new)
  end

  def teardown
    RecordingStudioAI.instance_variable_set(:@prompts, @original_prompts)
    RecordingStudioAI.instance_variable_set(:@tools, @original_tools)
  end

  def test_registered_prompt_renders_messages_uses_registered_tools_and_passes_attribution
    register_tool
    definition = register_prompt
    invocation = RecordingStudioAI.prompt(:support, :customer_reply, version: 1)
    captured_request = invocation.send(
      :request,
      { customer_name: "Ada", message: "Where is my order?" },
      { root_recording: Object.new, initiator: Object.new }
    )

    assert_equal definition, captured_request.fetch(:prompt_definition)
    assert_equal [{ role: "user", content: "Ada: Where is my order?" }], captured_request.fetch(:messages)
    assert_equal [{ key: "registered_tool", version: 1 }], captured_request.fetch(:custom_tools)
  end

  def test_registered_prompt_rejects_missing_inputs_and_duplicate_versions
    register_prompt

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.prompt(:support, :customer_reply).call(inputs: {}, root_recording: Object.new, initiator: Object.new)
    end
    assert_equal "invalid_request", error.code

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) { register_prompt }
  end

  def test_request_validation_rejects_unregistered_prompt_definitions
    definition = RecordingStudioAI::Prompts::Definition.new(**prompt_attributes(owner: :host_app))

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::RequestValidation.send(:ensure_prompt_definition!, definition)
    end

    assert_equal "invalid_request", error.code
    assert_equal "prompt_definition must be a registered prompt definition", error.message
  end

  def test_method_style_invocation_and_owner_replacement
    register_tool
    register_prompt(owner: :host_app)

    assert RecordingStudioAI.prompt_methods.respond_to?(:support)
    assert RecordingStudioAI.prompt_methods.support.respond_to?(:customer_reply)

    RecordingStudioAI.prompts.replace_owner(:host_app) do |registry|
      registry.register(**prompt_attributes(owner: :host_app, short_name: "Reply"))
    end

    assert_equal "Reply", RecordingStudioAI.prompts.fetch(:support, :customer_reply).short_name
  end

  private

  def register_prompt(owner: nil)
    RecordingStudioAI.prompts.register(**prompt_attributes(owner: owner))
  end

  def prompt_attributes(owner:, short_name: "Support Reply")
    {
      owner: owner,
      namespace: :support,
      key: :customer_reply,
      version: 1,
      name: "Customer Support Reply",
      short_name: short_name,
      description: "Creates a concise customer response.",
      inputs: %i[customer_name message],
      messages: [{ role: :user, content: "{{customer_name}}: {{message}}" }],
      tools: [{ key: :registered_tool, version: 1 }]
    }
  end

  def register_tool
    RecordingStudioAI.tools.register(
      key: :registered_tool,
      version: 1,
      name: "Registered Tool",
      description: "A prompt tool.",
      use_when: "The prompt needs it.",
      do_not_use_when: "The prompt does not need it.",
      parameters: [],
      returns: "A result.",
      cost: :negligible,
      latency: :instant,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Test",
      executor: ->(_arguments, _context) { {} }
    )
  end
end