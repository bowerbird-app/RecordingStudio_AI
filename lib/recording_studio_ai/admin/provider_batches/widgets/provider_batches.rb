# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIProviderBatchesWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.provider_batches") do
    type :list
    title "Provider batches"
    subtitle "Recent provider batches in the last 30 days."
    description "Open a batch to inspect items, status, and usage."
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.batches_scope(context)
                                                   .where(created_at: 30.days.ago..Time.current)
                                                   .order(created_at: :desc)
                                                   .limit(3)
      rows.map do |batch|
        {
          icon: :queue_list,
          text: "#{batch.provider.presence || 'Unknown'} / #{batch.model.presence || 'Unknown'}",
          trailing: batch.status.to_s.humanize,
          href: "/recording_studio_ai/admin/batches/#{batch.id}"
        }
      end.presence || [{ text: "No provider batches in the last 30 days." }]
    end
    link_to { |context| context.admin_screen_path("provider_batches") }
  end
end
