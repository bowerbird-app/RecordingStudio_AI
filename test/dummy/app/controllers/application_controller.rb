class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes if respond_to?(:stale_when_importmap_changes)

  include RecordingStudio::RootSwitchable::ControllerSupport
  include RecordingStudio::UsesDefaultLayout

  layout :application_layout

  before_action :authenticate_user!
  before_action :set_current_actor
  before_action :assign_access_page_actions, unless: :devise_controller?

  private

  def application_layout
    return "application" if devise_controller?

    "recording_studio/default_layout"
  end

  def set_current_actor
    Current.actor = current_user
  end

  # default_layout page-nav right slot is Access only — no Sign out, root
  # switcher, or admin/root dropdown.
  def assign_access_page_actions
    recording = current_root_recording
    return if recording.blank?

    helpers.recording_studio_page_nav_right do
      helpers.recording_studio_accessible_avatars(
        recording,
        button_style: :ghost,
        button_size: :md
      )
    end
  end
end
