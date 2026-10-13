# frozen_string_literal: true

# Test/dev-only plain-text probes for i18n boot-order and plural render checks.
# Not product UI (RecordingStudio_search #16 pattern).
class I18nProbesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :set_current_actor

  def expensive_model
    render plain: I18n.t(
      "recording_studio.ai.admin.alerts.expensive_model",
      share: params.fetch(:share, "40")
    )
  end

  def high_usage
    count = Integer(params.fetch(:count))
    render plain: AdminScreens::RecordingStudioAIWidgets.high_usage_alert_text(count)
  end
end

