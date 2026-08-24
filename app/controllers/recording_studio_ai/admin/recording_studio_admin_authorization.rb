# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    # Copy Recording Studio Admin's Accessible gate when that gem is loaded.
    # This file lives under app/controllers so Zeitwerk reloads it with Admin.
    module RecordingStudioAdminAuthorization
      ADMIN_SURFACE_KEY = "admin"

      module_function

      def available?
        defined?(::RecordingStudioAdmin) && defined?(::RecordingStudioAccessible)
      end

      def context_for(controller:)
        ::RecordingStudioAdmin::Context.new(
          params: controller.params.to_unsafe_h,
          current_actor: actor_for(controller),
          controller: controller,
          routes: controller,
          view_context: controller.respond_to?(:view_context) ? controller.view_context : nil,
          surface: surface_for
        )
      end

      def authorize!(context)
        ::RecordingStudioAdmin::Authorization.authorize!(context)
      end

      def actor_for(controller)
        return Current.actor if defined?(Current) && Current.respond_to?(:actor) && !Current.actor.nil?

        method_name = ::RecordingStudioAdmin.configuration.current_actor_method
        controller.send(method_name) if method_name && controller.respond_to?(method_name, true)
      end

      def surface_for
        ::RecordingStudioAdmin.configuration.surface_for(ADMIN_SURFACE_KEY)
      end
    end
  end
end
