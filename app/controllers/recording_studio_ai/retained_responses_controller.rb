# frozen_string_literal: true

module RecordingStudioAI
  class RetainedResponsesController < ::ApplicationController
    include RecordingStudio::UsesDefaultLayout

    RESOURCE_KEY = "recording_studio_ai_retained_responses"

    before_action :require_recording_studio_admin
    before_action :discard_default_layout_notice
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

    def show
      assign_saved_reply_page
    rescue ::RecordingStudioAdmin::AuthorizationFailed
      head :forbidden
    rescue RecordingStudioAI::Errors::ContractValidationError => e
      raise unless e.code == "authorization"

      head :forbidden
    end

    private

    def require_recording_studio_admin
      raise ActiveRecord::RecordNotFound unless defined?(::RecordingStudioAdmin)
    end

    def render_not_found
      head :not_found
    end

    def assign_saved_reply_page
      context = authorize_admin_context!
      retained = load_authorized_retained_response!(context)
      assign_reply_ivars(context, retained)
    end

    def assign_reply_ivars(context, retained)
      @reply = RecordingStudioAI.read_retained_response(
        response: retained,
        initiator: context.current_actor,
        execution_source: :admin
      )
      @call = AdminScreens::RecordingStudioAIWidgets.response_run(retained)
      @call_path = call_attempts_path(context, @call)
      @access_recording = context.access_recording
      @admin_home_path = ::RecordingStudioAdmin.configuration.default_mount_path
    end

    def authorize_admin_context!
      context = admin_context
      ::RecordingStudioAdmin::Authorization.authorize!(context)
      context
    end

    def load_authorized_retained_response!(context)
      retained = AdminScreens::RecordingStudioAIWidgets.responses_scope(context).find(params[:id])
      ::RecordingStudioAdmin.authorize_resource!(
        key: RESOURCE_KEY,
        action: :show,
        context: context,
        record: retained
      )
      retained
    end

    def admin_context
      @admin_context ||= ::RecordingStudioAdmin::Context.new(
        params: params.to_unsafe_h,
        current_actor: admin_actor,
        controller: self,
        routes: self,
        view_context: view_context,
        surface: ::RecordingStudioAdmin.configuration.surface_for("admin")
      )
    end

    def admin_actor
      return Current.actor if defined?(Current) && Current.respond_to?(:actor) && !Current.actor.nil?

      method_name = ::RecordingStudioAdmin.configuration.current_actor_method
      send(method_name) if method_name && respond_to?(method_name, true)
    end

    def discard_default_layout_notice
      flash.delete(:notice)
    end

    def call_attempts_path(context, call)
      return if call.blank?

      query = { run_id: call.id }.to_query
      "#{context.admin_screen_path('attempts')}?#{query}"
    end
  end
end
