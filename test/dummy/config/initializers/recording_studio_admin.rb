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

module RecordingStudioAdminRootAnchorDefault
  private

  def page_nav_anchor_url(default: nil)
    super(default: RecordingStudioAdmin.configuration.default_mount_path)
  end

  def preserve_anchor_url(url)
    safe_url = RecordingStudioAdmin::UrlSafety.safe_href(url)
    return safe_url if safe_url.blank?
    return safe_url if safe_url.start_with?("/admin/screens/")

    super
  end
end

Rails.application.config.to_prepare do
  if defined?(RecordingStudioAdmin::ApplicationController) &&
      !RecordingStudioAdmin::ApplicationController.ancestors.include?(RecordingStudioAdminRootAnchorDefault)
    RecordingStudioAdmin::ApplicationController.prepend(RecordingStudioAdminRootAnchorDefault)
  end
end
