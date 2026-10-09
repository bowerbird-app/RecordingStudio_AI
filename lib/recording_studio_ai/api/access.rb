# frozen_string_literal: true

module RecordingStudioAI
  module Api
    module Access
      module_function

      ResolverContext = Struct.new(:controller)

      def admin_root_recording
        return unless defined?(RecordingStudioAdmin)

        config = RecordingStudioAdmin.configuration
        resolver = config.site_admin_recording_resolver || config.access_recording_resolver
        return unless resolver

        begin
          resolver.call(ResolverContext.new(nil))
        rescue StandardError
          nil
        end
      end

      def actor_for(context)
        context&.access_grant&.actor
      end

      def can_view?(context)
        authorized_on_admin_root?(context, :view)
      end

      def authorized_on_admin_root?(context, role)
        actor = actor_for(context)
        recording = admin_root_recording
        return false if actor.blank? || recording.blank?
        return false unless defined?(RecordingStudioAccessible)

        RecordingStudioAccessible.authorized?(
          actor: actor,
          recording: recording,
          role: role
        )
      end
    end
  end
end
