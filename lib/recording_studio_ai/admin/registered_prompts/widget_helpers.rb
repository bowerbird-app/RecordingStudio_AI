# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def prompt_rows(context)
      runs = runs_scope(context).where.not(prompt_key: nil)
      date_range = prompt_created_at_range(registered_prompts_date_range_value(context)) || (30.days.ago..Time.current)
      range_runs = runs.where(created_at: date_range)
      range_counts = range_runs.group(:prompt_key, :prompt_version).count
      daily_counts = grouped_daily_counts(
        range_runs,
        :prompt_key,
        :prompt_version,
        column: "#{RecordingStudioAI::Run.table_name}.created_at"
      )
      completed_counts = range_runs.where(status: "completed").group(:prompt_key, :prompt_version).count
      error_counts = range_runs.where(status: %w[failed cancelled]).group(:prompt_key, :prompt_version).count
      average_latencies = range_runs.group(:prompt_key, :prompt_version).average(:latency_ms)
      average_input_tokens = range_runs.group(:prompt_key, :prompt_version).average(:input_tokens)
      average_output_tokens = range_runs.group(:prompt_key, :prompt_version).average(:output_tokens)

      RecordingStudioAI.prompts.all.map do |definition|
        key = [definition.key, definition.version]
        total = range_counts.fetch(key, 0)

        PromptRow.new(
          definition.key,
          definition.version,
          definition.name,
          definition.owner,
          definition.description,
          total,
          (date_range.begin.to_date..date_range.end.to_date).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([*key, date], 0) }
          end,
          percentage(completed_counts.fetch(key, 0), total),
          percentage(error_counts.fetch(key, 0), total),
          duration(average_latencies[key]),
          average_tokens(average_input_tokens[key]),
          average_tokens(average_output_tokens[key])
        )
      end.sort_by { |row| [-row.calls, row.key, row.version] }
    end

    def average_tokens(value)
      return Copy.t("common.no_data") if value.blank?

      number(value.round)
    end

    def top_prompt_call_rows(scope, range: 30.days.ago..Time.current, limit: 5)
      top = scope.where(created_at: range)
                 .where.not(prompt_key: nil)
                 .group(:prompt_key)
                 .count
                 .sort_by { |_identity, count| -count }
                 .first(limit)
      return [] if top.empty?

      snapshot_names = latest_prompt_name_snapshots(scope, top.map(&:first))
      top.filter_map do |prompt_key, calls|
        definition = RecordingStudioAI.prompts.fetch(prompt_key) if prompt_key.present?
        name = definition&.name || snapshot_names[prompt_key] || prompt_key
        [name, prompt_key, calls]
      end
    end

    def latest_prompt_name_snapshots(scope, keys)
      return {} if keys.empty?

      rows = scope.where(prompt_key: keys)
                  .where.not(prompt_name_snapshot: [nil, ""])
                  .order(created_at: :desc)
                  .pluck(:prompt_key, :prompt_name_snapshot)

      rows.each_with_object({}) do |(prompt_key, name), memo|
        memo[prompt_key] ||= name
      end
    end

    def prompt_chart_label(row)
      "#{row.name} (#{row.key} v#{row.version})"
    end

    def prompt_calls_path(context, row)
      range_query = date_range_query(
        context,
        screen: AdminScreens::RecordingStudioAIRegisteredPromptsScreen
      )
      query = range_query.merge(
        prompt: row.key,
        prompt_version: row.version
      )
      "/admin/screens/ai_calls?#{query.to_query}"
    end

    def registered_prompts_date_range_value(context)
      return context.filter_value(:date_range) if context.filter_value(:date_range)

      screen = AdminScreens::RecordingStudioAIRegisteredPromptsScreen
      screen.filters.find { |filter| filter.key == :date_range }.normalize(context.params)
    end

    def prompt_call_count(context, date_range:)
      range = prompt_created_at_range(date_range)
      return 0 unless range

      runs_scope(context).where.not(prompt_key: nil).where(created_at: range).count
    end

    def prompt_created_at_range(date_range)
      return unless date_range.respond_to?(:start_date) && date_range.respond_to?(:end_date)
      return unless date_range.start_date && date_range.end_date

      date_range.start_date.beginning_of_day..date_range.end_date.end_of_day
    end

    def prompt_definition_modal(row)
      definition = RecordingStudioAI.prompts.fetch(row.key, version: row.version)
      definition_modal(
        modal_id: "registered-prompt-definition-#{row.key}-#{row.version}",
        title: "#{definition.name} v#{definition.version}",
        trigger_text: "#{row.name} v#{row.version}",
        aria_label: Copy.t("common.show_definition_for", name: row.name),
        fields: {
          Copy.t("admin.definition_fields.prompt_key") => definition.key,
          Copy.t("admin.definition_fields.registered_by") => definition.owner.presence || Copy.t("common.none"),
          Copy.t("admin.definition_fields.description") => definition.description,
          Copy.t("admin.definition_fields.inputs") => definition.inputs.presence&.join(", ") || Copy.t("common.none_word"),
          Copy.t("admin.definition_fields.tools") => prompt_tool_labels(definition),
          Copy.t("admin.definition_fields.defaults") => definition.defaults.presence&.map { |key, value| "#{key}: #{value}" }&.join(", ") || Copy.t("common.none_word")
        },
        trailing: prompt_messages_markup(definition.messages)
      )
    end

    def prompt_tool_labels(definition)
      return Copy.t("common.none_word") if definition.tools.empty?

      definition.tools.map do |tool|
        tool[:version] ? "#{tool.fetch(:key)} v#{tool[:version]}" : tool.fetch(:key)
      end.join(", ")
    end

    def prompt_messages_markup(messages)
      helpers = ActionController::Base.helpers
      helpers.content_tag(:div, class: "grid gap-3") do
        helpers.safe_join(messages.map { |message| prompt_message_block(message) })
      end
    end

    def prompt_message_block(message)
      render_flatpack(
        FlatPack::CodeBlock::Component.new(
          title: prompt_message_title(message.fetch(:role)),
          language: "text",
          code: message.fetch(:content).to_s,
          separated: false
        )
      )
    end

    def prompt_message_title(role)
      case role.to_s
      when "system" then Copy.t("common.system_prompt")
      when "user" then Copy.t("common.user_prompt")
      else
        # Match main: non-system/user roles use role.humanize ("assistant" => "Assistant").
        english = role.to_s.humanize
        Copy.t("common.role.#{role}", default: english)
      end
    end
  end
end
