# frozen_string_literal: true

RecordingStudioAccessible.configure do |config|
  # Keep this enabled if you want an info-level log when RecordingStudio still owns
  # the built-in access constants and this addon is running in compatibility mode.
  config.warn_on_core_conflict = true

  # Optional: resolve the submitted email to an actor for new access grants.
  # config.access_management_actor_email_resolver = lambda do |controller:, email:|
  #   User.find_by(email: email.to_s.strip.downcase)
  # end

  # Optional: customize how the mounted engine resolves the acting user.
  # By default it uses Current.actor so the addon follows the same actor source
  # RecordingStudio uses, and only falls back to controller.current_user when
  # Current.actor is unavailable.
  # config.access_management_current_actor_resolver = lambda do |controller:|
  #   Current.actor || controller.current_user
  # end

  # Optional: customize what happens when no existing user matches the submitted
  # email. The built-in default keeps the current "not found" error until your
  # host app decides how to provision or resolve that recipient.
  #
  # The controller passes these keyword arguments to the handler:
  # - email: the submitted email address
  # - controller: the engine controller instance handling the request
  # - recording: the recording being granted
  # - role: the requested role string
  # - manager_actor: the current actor performing the grant
  #
  # The handler may return:
  # - an actor record to grant access immediately
  # - RecordingStudioAccessible::MissingActorResolution.created(actor: user, notice: ...)
  # - RecordingStudioAccessible::MissingActorResolution.redirect(location: ..., alert: ...)
  # - RecordingStudioAccessible::MissingActorResolution.invalid(error: ...)
  #
  # Prefer :invalid or :requires_resolution until your app has verified the
  # recipient and completed any required setup. Returning an actor or :created
  # continues the original grant immediately.
  #
  # config.access_management_missing_actor_handler = lambda do |controller:, email:, **|
  #   normalized_email = email.to_s.strip.downcase
  #   next RecordingStudioAccessible::MissingActorResolution.invalid(error: "User is required") if normalized_email.blank?
  #
  #   RecordingStudioAccessible::MissingActorResolution.redirect(
  #     location: controller.main_app.url_for(
  #       controller: "/users",
  #       action: :new,
  #       email: normalized_email,
  #       only_path: true
  #     ),
  #     alert: "Review #{normalized_email} before granting access",
  #     status: :requires_resolution
  #   )
  # end

  # Optional: customize the post-grant share email.
  # The built-in notifier sends RecordingStudioAccessible::AccessGrantedMailer
  # after a successful grant using the templates copied to:
  # app/views/recording_studio_accessible/access_granted_mailer/
  #
  # The controller only calls this notifier after the grant service succeeds.
  # Provisioning a user does not send the share email by itself.
  #
  # config.access_management_access_granted_subject = lambda do |recording:, **|
  #   "A recording was shared with you: #{RecordingStudio::Labels.title_for(recording.recordable)}"
  # end
  #
  # config.access_management_access_granted_url_resolver = lambda do |controller:, recording:, **|
  #   controller.main_app.polymorphic_url(recording.recordable)
  # end
  #
  # config.access_management_access_granted_notifier = lambda do |controller:, recording:, actor:, role:, manager_actor:|
  #   RecordingStudioAccessible::AccessGrantedMailer.with(
  #     controller: controller,
  #     recording: recording,
  #     actor: actor,
  #     role: role,
  #     manager_actor: manager_actor,
  #     subject: "A recording was shared with you",
  #     access_url: controller.main_app.polymorphic_url(recording.recordable)
  #   ).access_granted.deliver_now
  # end

  # Optional: customize how actors are labeled in the access management UI.
  # config.access_management_actor_label = ->(actor) { actor.email }

  # Optional: customize who can manage access for a recording.
  # config.access_management_authorizer = lambda do |recording:, actor:, **|
  #   actor.present? && RecordingStudioAccessible.authorized?(
  #     actor: actor,
  #     recording: recording,
  #     role: :admin
  #   )
  # end

  # Optional: customize who can view the mounted addon overview/docs/email-preview
  # pages under /recording_studio_accessible. The default is fail-closed unless
  # the current actor has admin access to the resolved demo root recording.
  # config.mounted_page_authorizer = lambda do |controller:, actor:, recording:|
  #   actor.present? && recording.present? && RecordingStudioAccessible.authorized?(
  #     actor: actor,
  #     recording: recording,
  #     role: :admin
  #   )
  # end
end
