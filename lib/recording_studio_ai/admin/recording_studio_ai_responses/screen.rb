# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIResponsesScreen < RecordingStudioAdmin::Screen
    key "recording_studio_ai_responses"
    icon :table
    title "AI Responses"
    subtitle "Persisted response records from Recording Studio AI executions."

    query do |_context|
      RecordingStudioAI::Response.includes(attempt: :run, batch_item: :run).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_30_days
    filter :type,
           values: lambda {
             RecordingStudioAI::Response.distinct.order(:response_type).pluck(:response_type).compact_blank
           },
           apply: ->(relation, value, _context) { relation.where(response_type: value) }
    filter :provider,
           options: -> { RecordingStudioAI::Response.distinct.order(:provider).pluck(:provider).compact_blank }
    filter :model,
           options: -> { RecordingStudioAI::Response.distinct.order(:model).pluck(:model).compact_blank }
    filter :finish,
           options: lambda {
             RecordingStudioAI::Response.distinct.order(:finish_reason).pluck(:finish_reason).compact_blank
           },
           apply: ->(relation, value, _context) { relation.where(finish_reason: value) }
    filter :complete,
           values: ["1"],
           control: :checkbox,
           apply: ->(relation, _value, _context) { relation.where(complete: true) }

    table do
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "provider ILIKE :search",
              "model ILIKE :search",
              "response_type ILIKE :search",
              "provider_response_id ILIKE :search",
              "finish_reason ILIKE :search",
              "CAST(attempt_id AS TEXT) ILIKE :search",
              "CAST(batch_item_id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :created_at, title: "Created"
      column :response,
             title: "Response",
             sortable: false,
             value: lambda { |row, _context|
               ActionController::Base.helpers.link_to(
                 "Response ##{row.id}",
                 "/recording_studio_ai/admin/retained_responses/#{row.id}",
                 class: "text-(--color-primary-background-color) underline",
                 data: { turbo_frame: "_top" }
               )
             }
      column :response_type,
             title: "Type",
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = value.to_s == "error" ? :danger : :default
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :source,
             sortable: false,
             value: lambda { |row, _context|
               row.attempt_id.present? ? "Attempt ##{row.attempt_id}" : "Batch item ##{row.batch_item_id}"
             }
      column :run_id,
             title: "Run",
             sortable: false,
             value: ->(row, _context) { row.attempt&.run_id || row.batch_item&.run_id }
      column :provider
      column :model
      column :finish_reason, title: "Finish", sortable: false
      column :completion,
             title: "Complete",
             sortable: false,
             value: lambda { |row, _context|
               if row.complete.nil?
                 "Unknown"
               elsif row.complete
                 "Yes"
               else
                 "No"
               end
             },
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value
                       when "Yes" then :success
                       when "No" then :warning
                       else :default
                       end
               { text: value, style: style, size: :sm }
             }
      column :byte_size, title: "Bytes"
      column :expires_at, title: "Expires"

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end
end
