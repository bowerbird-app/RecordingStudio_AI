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
    @admin_root = RecordingStudio.root_recording_for(workspace)
    grant_accessible!(recording: @admin_root, actor: @staff, role: :admin)
    Current.actor = nil
  end

  teardown do
    Current.actor = nil
  end

  test "site resolver is preferred when it is set" do
    seen = nil
    access_called = false

    with_resolvers(
      site: lambda do |context|
        seen = context
        @admin_root
      end,
      access: lambda do |_context|
        access_called = true
        nil
      end
    ) do
      assert RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
    end

    assert_nil seen.controller
    refute access_called
  end

  test "access resolver is used when the site resolver is unset" do
    seen = nil

    with_resolvers(
      site: nil,
      access: lambda do |context|
        seen = context
        @admin_root
      end
    ) do
      assert RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
    end

    assert_nil seen.controller
  end

  test "a raising resolver denies the view" do
    result = nil

    with_resolvers(
      site: ->(_context) { raise NoMethodError, "controller is nil" },
      access: ->(_context) { @admin_root }
    ) do
      result = assert_nothing_raised do
        RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
      end
    end

    refute result
  end

  test "a nil admin root denies the view" do
    access_called = false

    with_resolvers(
      site: ->(_context) { nil },
      access: lambda do |_context|
        access_called = true
        @admin_root
      end
    ) do
      refute RecordingStudioAI::Api::Access.can_view?(view_context(@staff))
    end

    refute access_called
  end

  private

  def view_context(actor)
    GrantContext.new(Grant.new(actor))
  end

  def with_resolvers(site:, access:)
    config = RecordingStudioAdmin.configuration
    original_site = config.site_admin_recording_resolver
    original_access = config.access_recording_resolver
    config.site_admin_recording_resolver = site
    config.access_recording_resolver = access
    yield
  ensure
    config.site_admin_recording_resolver = original_site
    config.access_recording_resolver = original_access
  end
end
