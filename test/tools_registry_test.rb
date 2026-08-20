# frozen_string_literal: true

require "test_helper"

class ToolsRegistryTest < Minitest::Test
  def setup
    @registry = RecordingStudioAI::Tools::Registry.new
  end

  def test_duplicate_registration_raises_without_override
    register_tool!

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { register_tool! }
    assert_match(/already registered/, error.message)
  end

  def test_override_replaces_existing_registration
    register_tool!(name: "First")
    definition = register_tool!(name: "Second", override: true)

    assert_equal "Second", definition.name
    assert_equal "Second", @registry.fetch(:echo_tool, version: 1).name
    assert_equal 1, @registry.all.length
  end

  private

  def register_tool!(name: "Echo tool", override: false)
    @registry.register(
      key: :echo_tool,
      version: 1,
      name: name,
      description: "Echoes input.",
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
      executor_label: "Tests.echo",
      executor: ->(_arguments, _context) { { ok: true } },
      override: override
    )
  end
end
