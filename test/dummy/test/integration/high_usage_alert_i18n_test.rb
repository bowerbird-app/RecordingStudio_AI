# frozen_string_literal: true

require "test_helper"

class HighUsageAlertI18nTest < ActionDispatch::IntegrationTest
  setup do
    workspace = Workspace.create!(name: "High usage workspace")
    @root = RecordingStudio.root_recording_for(workspace)
    @user = User.create!(email: "high-usage-#{SecureRandom.hex(4)}@example.com", password: "Password123!")
  end

  test "warning_items high_usage english matches main for many" do
    now = Time.current
    20.times do
      RecordingStudioAI::Run.create!(
        operation: "generation",
        status: "completed",
        resolved_model: "gpt-test",
        resolved_provider: "openai",
        root_recording_id: @root.id,
        context_recording_id: @root.id,
        initiator_type: "User",
        initiator_id: @user.id,
        initiator_kind: "user",
        created_at: now
      )
    end

    I18n.with_locale(:en) do
      warnings = AdminScreens::RecordingStudioAIWidgets.warning_items(
        RecordingStudioAI::Run.where(root_recording_id: @root.id)
      )
      texts = warnings.map { |warning| warning.fetch(:text) }

      assert_includes texts, "Unusually high usage today: 20 calls"
    end
  end

  test "high_usage alert english uses singular call for count one at call site" do
    # Threshold is always >= 20, so :one never fires through warning_items.
    I18n.with_locale(:en) do
      text = AdminScreens::RecordingStudioAIWidgets.high_usage_alert_text(1)
      assert_equal "Unusually high usage today: 1 call", text
    end
  end
end
