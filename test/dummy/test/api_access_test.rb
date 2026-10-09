# frozen_string_literal: true

require "test_helper"

class ApiAccessTest < ActiveSupport::TestCase
  include AccessibleTestHelpers

  Grant = Struct.new(:actor)
  RequestContext = Struct.new(:access_grant)

  setup do
    @staff = User.create!(
      email: "api-access-#{SecureRandom.hex(4)}@example.com",
      password: "Password",
      password_confirmation: "Password"
    )
    Current.actor = @staff
    granted = Workspace.create!(name: "Granted #{SecureRandom.hex(4)}")
    denied = Workspace.create!(name: "Denied #{SecureRandom.hex(4)}")
    @granted_root = RecordingStudio.root_recording_for(granted)
    @denied_root = RecordingStudio.root_recording_for(denied)
    grant_accessible!(recording: @granted_root, actor: @staff, role: :view)
    Current.actor = nil
  end

  teardown do
    Current.actor = nil
  end

  test "site resolver is preferred when it is set" do
    access_called = false
    with_resolvers(
      site: lambda do |context|
        assert_nil context.controller
        @granted_root
      end,
      access: lambda do |_context|
        access_called = true
        @denied_root
      end
    ) do
      assert_equal true, RecordingStudioAI::Api::Access.can_view?(request_context(@staff))
      refute access_called
    end
  end

  test "falls back to the access resolver" do
    with_resolvers(
      site: nil,
      access: lambda do |context|
        assert_nil context.controller
        @granted_root
      end
    ) do
      assert_equal true, RecordingStudioAI::Api::Access.can_view?(request_context(@staff))
    end

    with_resolvers(site: nil, access: ->(_context) { @denied_root }) do
      assert_equal false, RecordingStudioAI::Api::Access.can_view?(request_context(@staff))
    end
  end

  test "resolver raising denies without an exception" do
    with_resolvers(
      site: nil,
      access: lambda do |context|
        assert_nil context.controller
        raise NoMethodError, "undefined method `current_root_recording' for nil"
      end
    ) do
      result = nil
      assert_nothing_raised do
        result = RecordingStudioAI::Api::Access.can_view?(request_context(@staff))
      end

      assert_equal false, result
    end
  end

  test "resolver returning nil denies" do
    access_called = false
    with_resolvers(
      site: ->(_context) { nil },
      access: lambda do |_context|
        access_called = true
        @granted_root
      end
    ) do
      assert_equal false, RecordingStudioAI::Api::Access.can_view?(request_context(@staff))
      refute access_called
    end
  end

  private

  def request_context(actor)
    RequestContext.new(Grant.new(actor))
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
