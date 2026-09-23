# frozen_string_literal: true

RecordingStudioAdmin.configure do |config|
  config.default_mount_path = "/admin"
  config.async_widgets.enabled = false
  config.authentication_method = :authenticate_user!
  config.current_actor_method = :current_user

  # Fail closed: never fall back to an ungranted or global root.
  config.access_recording_resolver = lambda do |context|
    actor = context.current_actor
    return nil if actor.blank?

    accessible_root_ids = DummyAccessibleAIAuthorization.accessible_root_ids(
      actor: actor,
      minimum_role: RecordingStudioAdmin.configuration.required_access_role || :view
    )
    return nil if accessible_root_ids.empty?

    current_root = context.controller.current_root_recording
    return current_root if current_root.present? && accessible_root_ids.include?(current_root.id)

    RecordingStudio::Recording.where(id: accessible_root_ids).order(:created_at).first
  end

  config.admin_sections_resolver = lambda do |recording:, context:, **|
    ["recording_studio_ai"]
  end
end

module RecordingStudioAdminLastFourWeeksPreset
  def from_preset_key(key, reference_date: Date.current)
    return super unless key.to_s == "last_4_weeks"

    RecordingStudioAdmin::Period.new(
      amount: 4,
      unit: :week,
      start_date: reference_date - 27.days,
      end_date: reference_date,
      preset_key: :last_4_weeks
    )
  end
end

RecordingStudioAdmin::Period.singleton_class.prepend(RecordingStudioAdminLastFourWeeksPreset)

module RecordingStudioAdminDiscardLayoutNotice
  extend ActiveSupport::Concern

  included do
    before_action :discard_default_layout_notice
  end

  private

  # default_layout renders leftover Devise "Signed in successfully." on /admin.
  def discard_default_layout_notice
    flash.delete(:notice)
  end
end

module RecordingStudioAdminRootAnchorDefault
  private

  def page_nav_anchor_url(default: nil)
    super(default: RecordingStudioAdmin.configuration.default_mount_path)
  end

  def preserve_anchor_url(url)
    safe_url = RecordingStudioAdmin::UrlSafety.safe_href(url)
    return safe_url if safe_url.blank?

    # /admin is the in-admin home, so it does not need to be copied onto every
    # screen link. A host return path, such as /, must survive screen navigation
    # or Close drops the operator back inside admin.
    anchor_url = page_nav_anchor_url
    admin_home = RecordingStudioAdmin.configuration.default_mount_path.to_s
    return safe_url if anchor_url.blank? || anchor_url == admin_home || anchor_url == "#{admin_home}/"

    super
  end
end

Rails.application.config.to_prepare do
  next unless defined?(RecordingStudioAdmin::ApplicationController)

  unless RecordingStudioAdmin::ApplicationController.ancestors.include?(RecordingStudio::UsesDefaultLayout)
    RecordingStudioAdmin::ApplicationController.include(RecordingStudio::UsesDefaultLayout)
  end

  unless RecordingStudioAdmin::ApplicationController.ancestors.include?(RecordingStudioAdminRootAnchorDefault)
    RecordingStudioAdmin::ApplicationController.prepend(RecordingStudioAdminRootAnchorDefault)
  end

  unless RecordingStudioAdmin::ApplicationController.ancestors.include?(RecordingStudioAdminDiscardLayoutNotice)
    RecordingStudioAdmin::ApplicationController.include(RecordingStudioAdminDiscardLayoutNotice)
  end
end
