# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class Access
      attr_reader :actor, :root_ids

      def initialize(controller:, configuration: RecordingStudioAI.configuration)
        @configuration = configuration
        @controller = controller
        @actor = resolve_actor!
        @root_ids = resolve_root_ids!
        root_ids.each { |root_id| authorize!(:view_execution, root_id: root_id) }
      end

      def authorize!(action, root_id:, context: {})
        Authorization.authorize!(
          action,
          attribution: Contracts::Attribution.new(
            root_recording: RecordingStudio::Recording.find(root_id),
            initiator: actor,
            execution_source: :admin
          ),
          context: context
        )
      end

      def allowed?(action, root_id:, context: {})
        authorize!(action, root_id: root_id, context: context)
      rescue RecordingStudioAI::Errors::ContractValidationError => error
        raise unless error.code == "authorization"

        false
      end

      private

      def resolve_actor!
        resolver = @configuration.admin_actor_resolver
        actor = resolver&.call(controller: @controller)
        actor || raise(ActiveRecord::RecordNotFound, "admin actor is unavailable")
      end

      def resolve_root_ids!
        resolver = @configuration.admin_visible_roots_resolver
        values = Array(resolver&.call(actor: actor, controller: @controller))
        ids = values.filter_map { |value| value.respond_to?(:id) ? value.id : value }.uniq
        ids.presence || raise(ActiveRecord::RecordNotFound, "no visible administration roots")
      end
    end
  end
end
