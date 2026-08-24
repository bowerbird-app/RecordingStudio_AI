# frozen_string_literal: true

RecordingStudioRootSwitchable.configure do |config|
  config.current_actor_resolver = lambda do |controller:|
    Current.actor || controller.current_user
  end

  # Render the mounted switcher pages inside the app shell when users visit them.
  config.layout = :application_layout

  config.after_switch_redirect = lambda do |controller:, return_to:, **|
    candidate_path = return_to.presence
    candidate_path = controller.main_app.root_path if candidate_path.blank?

    if internal_route?(candidate_path)
      candidate_path
    else
      controller.main_app.root_path
    end
  end

  # Keep the historical scope key so existing bookmarks/tests keep working, but
  # only list roots the actor can actually view via Accessible.
  config.scope :all_workspaces do |scope|
    scope.label = "Workspaces"
    scope.description = "Workspace roots you can access."
    scope.available_roots = lambda do |actor:, **|
      return [] if actor.blank?

      RecordingStudioAccessible.root_recordings_for(actor: actor, minimum_role: :view)
    end
    # Default access_check already calls Accessible with :view — leave it.

    scope.default_root = lambda do |roots:, **|
      roots.first
    end
  end
end

def internal_route?(path)
  routes = [
    Rails.application.routes,
    RecordingStudioRootSwitchable::Engine.routes
  ]

  routes.any? do |route_set|
    route_set.recognize_path(path, method: :get)
    true
  rescue StandardError
    false
  end
end
