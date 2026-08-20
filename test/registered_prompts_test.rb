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
    invocation = RecordingStudioAI.prompt(:customer_reply, version: 1)
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
      RecordingStudioAI.prompt(:customer_reply).call(inputs: {}, root_recording: Object.new, initiator: Object.new)
    end
    assert_equal "invalid_request", error.code

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) { register_prompt }
  end

  def test_registered_prompt_override_replaces_existing_registration
    register_prompt
    register_prompt(name: "Updated Reply", override: true)

    assert_equal "Updated Reply", RecordingStudioAI.prompts.fetch(:customer_reply).name
    assert_equal 1, RecordingStudioAI.prompts.all.length
  end

  def test_registered_prompt_override_rejected_when_not_overridable
    register_prompt(overridable: false)

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      register_prompt(name: "Host Override", override: true)
    end

    assert_equal "invalid_request", error.code
    assert_match(/not overridable/, error.message)
    assert_equal "Customer Support Reply", RecordingStudioAI.prompts.fetch(:customer_reply).name
  end

  def test_registered_prompt_override_allowed_when_marked_overridable
    register_prompt(owner: :support_gem, overridable: true)
    register_prompt(
      owner: :host_app,
      name: "Host Customer Reply",
      override: true,
      overridable: true,
      messages: [
        { role: :system, content: "Be brief and friendly." },
        { role: :user, content: "{{customer_name}}: {{message}}" }
      ]
    )

    definition = RecordingStudioAI.prompts.fetch(:customer_reply, version: 1)
    assert_equal "Host Customer Reply", definition.name
    assert_equal "host_app", definition.owner
    assert_equal "Be brief and friendly.", definition.messages.first.fetch(:content)
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

    assert RecordingStudioAI.prompt_methods.respond_to?(:customer_reply)

    RecordingStudioAI.prompts.replace_owner(:host_app) do |registry|
      registry.register(**prompt_attributes(owner: :host_app, name: "Updated Reply"))
    end

    assert_equal "Updated Reply", RecordingStudioAI.prompts.fetch(:customer_reply).name
  end

  private

  def register_prompt(owner: nil, name: "Customer Support Reply", override: false, overridable: true, **extras)
    RecordingStudioAI.prompts.register(
      **prompt_attributes(owner: owner, name: name, overridable: overridable, **extras),
      override: override
    )
  end

  def prompt_attributes(owner:, name: "Customer Support Reply", overridable: true, **extras)
    {
      owner: owner,
      key: :customer_reply,
      version: 1,
      name: name,
      description: "Creates a concise response to a customer message.",
      inputs: %i[customer_name message],
      messages: [
        { role: :user, content: "{{customer_name}}: {{message}}" }
      ],
      tools: [{ key: :registered_tool, version: 1 }],
      defaults: { profile: :medium, purpose: "customer_reply" },
      overridable: overridable
    }.merge(extras)
  end

  def register_tool
    RecordingStudioAI.tools.register(
      key: :registered_tool,
      version: 1,
      name: "Registered tool",
      description: "Tool for prompt tests.",
      use_when: "Testing.",
      do_not_use_when: "Never.",
      parameters: [],
      returns: "A result.",
      cost: :low,
      latency: :fast,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Tests.registered_tool",
      executor: ->(_arguments, _context) { { ok: true } }
    )
  end
end
