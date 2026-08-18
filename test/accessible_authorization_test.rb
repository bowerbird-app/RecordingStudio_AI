# frozen_string_literal: true

require "test_helper"

class AccessibleAuthorizationTest < Minitest::Test
  Actor = Data.define(:id)
  Attribution = Data.define(:initiator, :root_recording)

  def setup
    @actor = Actor.new(id: 1)
    @root = Actor.new(id: 99)
    @calls = []
    stub_accessible!
  end

  def teardown
    remove_accessible_stub!
  end

  def test_mapper_denies_execute_on_ungranted_root
    @authorized = false
    attribution = Attribution.new(initiator: @actor, root_recording: @root)

    refute RecordingStudioAI::AccessibleAuthorization.call(
      action: "recording_studio_ai.execute",
      attribution: attribution,
      context: {}
    ).equal?(true)

    assert_equal [[@actor, @root, :edit]], @calls
  end

  def test_mapper_allows_execute_when_accessible_grants_edit
    @authorized = true
    attribution = Attribution.new(initiator: @actor, root_recording: @root)

    assert_equal true, RecordingStudioAI::AccessibleAuthorization.call(
      action: "recording_studio_ai.execute",
      attribution: attribution,
      context: {}
    )
    assert_equal [[@actor, @root, :edit]], @calls
  end

  def test_mapper_uses_admin_role_for_sensitive_actions
    @authorized = true
    attribution = Attribution.new(initiator: @actor, root_recording: @root)

    assert_equal true, RecordingStudioAI::AccessibleAuthorization.call(
      action: "recording_studio_ai.view_sensitive_execution",
      attribution: attribution,
      context: {}
    )
    assert_equal [[@actor, @root, :admin]], @calls
  end

  def test_mapper_denies_unknown_actions_and_missing_attribution
    attribution = Attribution.new(initiator: @actor, root_recording: @root)

    refute RecordingStudioAI::AccessibleAuthorization.call(
      action: "recording_studio_ai.not_a_real_action",
      attribution: attribution,
      context: {}
    ).equal?(true)
    refute RecordingStudioAI::AccessibleAuthorization.call(
      action: "recording_studio_ai.execute",
      attribution: Attribution.new(initiator: nil, root_recording: @root),
      context: {}
    ).equal?(true)
    assert_empty @calls
  end

  def test_mapper_requires_accessible_constant
    remove_accessible_stub!

    assert_raises(LoadError) do
      RecordingStudioAI::AccessibleAuthorization.call(
        action: "recording_studio_ai.execute",
        attribution: Attribution.new(initiator: @actor, root_recording: @root),
        context: {}
      )
    end
  end

  def test_accessible_root_ids_and_admin_operator_use_minimum_role
    @authorized = true

    assert_equal [99], RecordingStudioAI::AccessibleAuthorization.accessible_root_ids(
      actor: @actor, minimum_role: :view
    )
    assert RecordingStudioAI::AccessibleAuthorization.admin_operator?(actor: @actor)

    @authorized = false
    assert_empty RecordingStudioAI::AccessibleAuthorization.accessible_root_ids(
      actor: @actor, minimum_role: :admin
    )
    refute RecordingStudioAI::AccessibleAuthorization.admin_operator?(actor: @actor)
    assert_empty RecordingStudioAI::AccessibleAuthorization.accessible_root_ids(actor: nil)
  end

  private

  def stub_accessible!
    return if defined?(::RecordingStudioAccessible)

    test_case = self
    Object.const_set(:RecordingStudioAccessible, Module.new)
    RecordingStudioAccessible.define_singleton_method(:authorized?) do |actor:, recording:, role:|
      test_case.instance_variable_get(:@calls) << [actor, recording, role]
      test_case.instance_variable_get(:@authorized)
    end
    RecordingStudioAccessible.define_singleton_method(:root_recording_ids_for) do |**|
      test_case.instance_variable_get(:@authorized) ? [99] : []
    end
    @remove_accessible_stub = true
  end

  def remove_accessible_stub!
    return unless @remove_accessible_stub

    Object.send(:remove_const, :RecordingStudioAccessible) if Object.const_defined?(:RecordingStudioAccessible)
    @remove_accessible_stub = false
  end
end
