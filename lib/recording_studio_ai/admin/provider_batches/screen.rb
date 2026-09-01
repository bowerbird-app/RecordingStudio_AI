# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIProviderBatchesScreen < RecordingStudioAdmin::Screen
    key "provider_batches"
    icon :queue_list
    title "Provider batches"
    subtitle "Submitted provider batch jobs across generation and structured output."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.batches_scope(context).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :status,
           param: :batch_status,
           field: :status,
           options: -> { RecordingStudioAI::Batch::STATUSES.values },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :provider,
           field: :provider,
           values: -> { AdminScreens::RecordingStudioAIWidgets.batch_distinct_values(:provider) },
           apply: ->(relation, value, _context) { relation.where(provider: value) }
    filter :model,
           field: :model,
           values: -> { AdminScreens::RecordingStudioAIWidgets.batch_distinct_values(:model) },
           apply: ->(relation, value, _context) { relation.where(model: value) }
    filter :profile,
           field: :profile_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.batch_present_distinct_values(:profile_key) },
           apply: ->(relation, value, _context) { relation.where(profile_key: value) }

    summary do
      change_good_when do |context|
        %w[failed cancelled expired partially_completed].include?(context.filter_value(:status).to_s) ? :down : :up
      end
    end

    chart do
      title "Provider batches trend"
      subtitle "How many batches were submitted over time."
      type :line
      series do |context|
        [{
          name: "Batches",
          data: RecordingStudioAdmin::AdminActivityLogsSupport.date_series(
            context.query_result.relation.reorder(nil),
            field: "recording_studio_ai_batches.created_at",
            bucket: context.filter_value(:group_by) || :day
          )
        }]
      end
      options do
        {
          height: 300,
          stroke: { curve: "smooth", width: 3 },
          xaxis: {
            labels: { show: true },
            axisBorder: { show: false },
            axisTicks: { show: false }
          },
          yaxis: { min: 0 },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "status ILIKE :search",
              "provider ILIKE :search",
              "model ILIKE :search",
              "profile_key ILIKE :search",
              "provider_batch_id ILIKE :search",
              "CAST(id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :created_at, title: "Created", header_tooltip: "When this batch was recorded."
      column :batch,
             title: "Batch",
             sortable: false,
             header_tooltip: "Open the batch detail page.",
             value: lambda { |batch, _context|
               ActionController::Base.helpers.link_to(
                 "Batch ##{batch.id}",
                 "/recording_studio_ai/admin/batches/#{batch.id}",
                 class: "text-(--color-primary-background-color) underline",
                 data: { turbo_frame: "_top" }
               )
             }
      column :status,
             header_tooltip: "How far this batch got.",
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed", "cancelled", "expired" then :danger
                       when "partially_completed" then :warning
                       when "preparing", "submitted", "processing" then :info
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :provider, title: "Provider", header_tooltip: "Who ran the batch."
      column :model, title: "Model", header_tooltip: "Which model the batch used."
      column :profile_key, title: "Profile", header_tooltip: "Which speed and quality mix was asked for."
      column :progress,
             title: "Progress",
             sortable: false,
             header_tooltip: "Finished items versus the full batch size.",
             value: lambda { |batch, _context|
               finished = batch.completed_item_count.to_i + batch.failed_item_count.to_i +
                          batch.cancelled_item_count.to_i
               "#{finished} / #{batch.item_count.to_i}"
             }
      column :failed_item_count, title: "Failed", header_tooltip: "Items that did not complete."
      column :total_tokens, title: "Tokens", header_tooltip: "Rough size across the whole batch."
      column :expires_at, title: "Expires", header_tooltip: "When the provider stops holding this batch."

      default_columns :created_at, :batch, :status, :provider, :model, :progress, :total_tokens
      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end
end
