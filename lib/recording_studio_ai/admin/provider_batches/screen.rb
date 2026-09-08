# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIProviderBatchesScreen < RecordingStudioAdmin::Screen
    key "provider_batches"
    icon :rectangle_stack
    title "Provider batches"
    subtitle "Jobs sent as a pack."

    query do |context|
      RecordingStudioAIWidgets.batches_scope(context).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :status, field: :status, values: -> { RecordingStudioAI::Batch::STATUSES.values }
    filter :provider, field: :provider,
           values: -> { RecordingStudioAIWidgets.batch_distinct_values(:provider) }

    table do
      column :created_at, title: "Created"
      column :status,
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed", "cancelled", "expired" then :danger
                       when "submitted", "processing", "preparing" then :info
                       when "partially_completed" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :provider
      column :model
      column :item_count,
             title: "Calls",
             value: lambda { |batch, context|
               count = batch.item_count.to_i
               next count if count.zero?

               ActionController::Base.helpers.link_to(
                 count,
                 RecordingStudioAIWidgets.run_filtered_screen_path(
                   context, "ai_calls", extra: { batch_id: batch.id }
                 ),
                 class: "text-(--color-primary-background-color)",
                 data: { turbo_frame: "_top" }
               )
             }
      column :failed_item_count, title: "Failed"
      column :total_tokens, title: "Tokens"
      column :expires_at, title: "Expires"
      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end
end
