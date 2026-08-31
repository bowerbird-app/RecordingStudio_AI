class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes if respond_to?(:stale_when_importmap_changes)

  include RecordingStudio::RootSwitchable::ControllerSupport
  helper RecordingStudio::LayoutHelper

  layout :application_layout

  before_action :authenticate_user!
  before_action :set_current_actor

  private

  def application_layout
    return "application" if devise_controller?

    "flat_pack_sidebar"
  end

  def set_current_actor
    Current.actor = current_user
  end
end
