# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def custom_tool_rows(context)
      invocations = tool_scope(context)
      date_range_value = registered_custom_tools_date_range_value(context)
      date_range = if date_range_value.respond_to?(:start_date) && date_range_value.respond_to?(:end_date)
                     date_range_value.start_date.beginning_of_day..date_range_value.end_date.end_of_day
                   else
                     30.days.ago..Time.current
                   end
      range_invocations = invocations.where(created_at: date_range)
      range_counts = range_invocations.group(:tool_key, :tool_version).count
      daily_counts = grouped_daily_counts(
        range_invocations,
        :tool_key,
        :tool_version,
        column: "#{RecordingStudioAI::CustomToolInvocation.table_name}.created_at"
      )
      completed_counts = range_invocations.where(status: "completed").group(:tool_key, :tool_version).count
      error_counts = range_invocations.where(status: %w[failed denied rejected cancelled]).group(:tool_key,
                                                                                                 :tool_version).count
      average_latencies = range_invocations.group(:tool_key, :tool_version).average(:latency_ms)

      RecordingStudioAI.tools.all.map do |definition|
        key = [definition.key, definition.version]
        total = range_counts.fetch(key, 0)
        safety = if definition.read_only
                   Copy.t("common.read_only_hyphen")
                 else
                   Copy.t("common.writes")
                 end
        safety = Copy.t("common.safety_with_destructive", safety: safety) if definition.destructive

        ToolRow.new(
          definition.key,
          definition.version,
          definition.name,
          definition.description,
          definition.cost,
          safety,
          (date_range.begin.to_date..date_range.end.to_date).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([*key, date], 0) }
          end,
          percentage(completed_counts.fetch(key, 0), total),
          percentage(error_counts.fetch(key, 0), total),
          duration(average_latencies[key])
        )
      end
    end

    def registered_custom_tools_date_range_value(context)
      return context.filter_value(:date_range) if context.filter_value(:date_range)

      screen = AdminScreens::RecordingStudioAIRegisteredCustomToolsScreen
      screen.filters.find { |filter| filter.key == :date_range }.normalize(context.params)
    end

    def custom_tool_definition_modal(row)
      definition = RecordingStudioAI.tools.fetch(row.key, version: row.version)
      definition_modal(
        modal_id: "custom-tool-definition-#{row.key}-#{row.version}",
        title: "#{definition.name} v#{definition.version}",
        trigger_text: "#{row.name} v#{row.version}",
        aria_label: Copy.t("common.show_definition_for", name: row.name),
        fields: {
          Copy.t("admin.definition_fields.description") => definition.description,
          Copy.t("admin.definition_fields.use_when") => definition.use_when,
          Copy.t("admin.definition_fields.do_not_use_when") => definition.do_not_use_when,
          Copy.t("admin.definition_fields.returns") => definition.returns,
          Copy.t("admin.definition_fields.executor") => definition.executor_label,
          Copy.t("admin.definition_fields.safety") => custom_tool_safety_line(definition)
        }
      )
    end

    def custom_tool_safety_line(definition)
      mode = if definition.read_only
               Copy.t("common.read_only")
             else
               Copy.t("common.writes")
             end
      Copy.t(
        "admin.safety.line",
        mode: mode,
        destructive: definition.destructive ? Copy.t("admin.safety.destructive_yes") : Copy.t("admin.safety.destructive_no"),
        confirmation: if definition.requires_confirmation
                        Copy.t("admin.safety.confirmation_required")
                      else
                        Copy.t("admin.safety.confirmation_not_required")
                      end,
        idempotent: definition.idempotent ? Copy.t("admin.safety.idempotent_yes") : Copy.t("admin.safety.idempotent_no")
      )
    end
  end
end
