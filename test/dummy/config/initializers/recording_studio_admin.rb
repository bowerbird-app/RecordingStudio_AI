# frozen_string_literal: true

RecordingStudioAdmin.configure do |config|
  config.default_mount_path = "/admin"
  config.engine_layout = "recording_studio_admin_blank"
  config.async_widgets.enabled = false
  config.authentication_method = :authenticate_user!
  config.current_actor_method = :current_user

  config.access_recording_resolver = lambda do |context|
    current_root = context.controller.current_root_recording
    actor = context.current_actor

    if actor
      accessible_root_ids = RecordingStudioAccessible.root_recording_ids_for(actor: actor, minimum_role: :view)
      return current_root if current_root.present? && accessible_root_ids.include?(current_root.id)

      accessible_root = RecordingStudio::Recording.where(id: accessible_root_ids).order(:created_at).first
      return accessible_root if accessible_root.present?
    end

    current_root || RecordingStudio::Recording.where(parent_recording_id: nil).order(:created_at).first
  end

  config.admin_sections_resolver = lambda do |recording:, context:, **|
    ["recording_studio_ai"]
  end
end

module RecordingStudioAdminRootAnchorDefault
  private

  def page_nav_anchor_url(default: nil)
    super(default: main_app.root_path)
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
