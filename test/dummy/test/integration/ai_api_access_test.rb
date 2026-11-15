# frozen_string_literal: true

require "test_helper"

class AIApiAccessTest < ActiveSupport::TestCase
  include AccessibleTestHelpers

  GrantContext = Struct.new(:access_grant)
  Grant = Struct.new(:actor)

  setup do
    @staff = User.create!(
      email: "api-access-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    Current.actor = @staff
    workspace = Workspace.create!(name: "API access #{SecureRandom.hex(4)}")
    @admin_root = ensure_root_recording!(workspace)
    grant_accessible!(recording: @admin_root, actor: @staff, role: :admin)
    Current.actor = nil
  end

  teardown do
    Current.actor = nil
  end

  test "admin root resolver allows a staff view" do
    seen = nil

    with_admin_root(lambda do |context:|
      seen = context
      @admin_root
    end) do
      assert RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
    end

    assert_equal({}, seen)
  end

  test "a raising resolver denies the view" do
    result = nil

    with_admin_root(->(**) { raise NoMethodError, "admin root missing" }) do
      result = assert_nothing_raised do
        RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
      end
    end

    refute result
  end

  test "a nil admin root denies the view" do
    with_admin_root(->(**) { nil }) do
      refute RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
    end
  end

  private

  def view_context(actor)
    GrantContext.new(Grant.new(actor))
  end

  def with_admin_root(resolver)
    config = RecordingStudioAccessible.configuration
    original = config.admin_root_resolver
    config.admin_root_resolver = resolver
    yield
  ensure
    config.admin_root_resolver = original
  end
end
