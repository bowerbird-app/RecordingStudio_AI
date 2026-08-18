# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    # Copy Recording Studio Admin's Accessible gate when that gem is loaded.
    # Screens call RecordingStudioAdmin::Authorization.authorize! against the
    # access recording and required_access_role (default :view). The retained
    # response viewer is linked from those screens, so it uses the same check.
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
        if defined?(Current) && Current.respond_to?(:actor) && !Current.actor.nil?
          return Current.actor
        end

        method_name = ::RecordingStudioAdmin.configuration.current_actor_method
        controller.send(method_name) if method_name && controller.respond_to?(method_name, true)
      end

      def surface_for
        ::RecordingStudioAdmin.configuration.surface_for(ADMIN_SURFACE_KEY)
      end
    end
  end
end
