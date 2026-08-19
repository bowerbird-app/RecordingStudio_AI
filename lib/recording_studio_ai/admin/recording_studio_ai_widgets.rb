# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    extend self

    EXPENSIVE_MODEL_MATCHER = /(gpt-5|o1|claude-opus|gemini-2\.5-pro)/i unless const_defined?(:EXPENSIVE_MODEL_MATCHER)
    WarningRow = Data.define(:text) unless const_defined?(:WarningRow)
    unless const_defined?(:ToolRow)
      ToolRow = Data.define(:key, :version, :name, :description, :cost_class, :safety, :calls_series, :success_rate,
                            :error_rate, :average_duration)
    end
    if const_defined?(:PromptRow) && PromptRow.members != %i[
      namespace key version name short_name description calls calls_series success_rate error_rate
      average_duration average_input_tokens average_output_tokens
    ]
      remove_const(:PromptRow)
    end
    unless const_defined?(:PromptRow)
      PromptRow = Data.define(:namespace, :key, :version, :name, :short_name, :description, :calls, :calls_series,
                              :success_rate, :error_rate, :average_duration, :average_input_tokens,
                              :average_output_tokens)
    end
    DateRangeWindow = Data.define(:start_date, :end_date, :preset_key) unless const_defined?(:DateRangeWindow)
    latency_row_members = %i[
      name calls calls_series p50_latency_ms p90_latency_ms average_latency_ms max_latency_ms
      prompt_namespace prompt_key prompt_version resolved_model
    ]
    remove_const(:LatencyRow) if const_defined?(:LatencyRow) && LatencyRow.members != latency_row_members
    LatencyRow = Data.define(*latency_row_members) unless const_defined?(:LatencyRow)

    module AttemptErrorCodeColumn
      ERROR_CODE_KEY = :error_code

      def columns
        defined_columns = super
        return defined_columns if RecordingStudioAIWidgets.attempt_error_code_column_visible?

        defined_columns.reject { |column| column.key == ERROR_CODE_KEY }
      end

      def default_column_keys
        return super if RecordingStudioAIWidgets.attempt_error_code_column_visible?

        Array(@default_column_keys) - [ERROR_CODE_KEY]
      end
    end
    provider_row_members = %i[key class_name configured models_count calls calls_series]
    remove_const(:ProviderRow) if const_defined?(:ProviderRow) && ProviderRow.members != provider_row_members
    ProviderRow = Data.define(*provider_row_members) unless const_defined?(:ProviderRow)
    model_row_members = %i[
      provider model temperature verbosity reasoning_effort streaming structured_output batch
      tools input_modalities output_modalities calls calls_series
    ]
    remove_const(:ModelRow) if const_defined?(:ModelRow) && ModelRow.members != model_row_members
    ModelRow = Data.define(*model_row_members) unless const_defined?(:ModelRow)

    unless const_defined?(:ATTEMPT_KIND_LABELS)
      ATTEMPT_KIND_LABELS = {
        "primary" => "1st attempt",
        "retry" => "Retry",
        "fallback" => "Fallback",
        "continuation" => "After tools"
      }.freeze
    end
    ADMIN_CONTEXT_KEY = :recording_studio_ai_admin_context unless const_defined?(:ADMIN_CONTEXT_KEY)

    def bind_admin_context!(context)
      Thread.current[ADMIN_CONTEXT_KEY] = context
      context
    end

    WIDGET_MEMO_KEY = :recording_studio_ai_widget_memo unless const_defined?(:WIDGET_MEMO_KEY)

    def clear_admin_context!
      Thread.current[ADMIN_CONTEXT_KEY] = nil
      Thread.current[WIDGET_MEMO_KEY] = nil
    end

    def admin_context
      Thread.current[ADMIN_CONTEXT_KEY]
    end

    def memoize_widget(key)
      store = (Thread.current[WIDGET_MEMO_KEY] ||= {})
      return store[key] if store.key?(key)

      store[key] = yield
    end

    # DATE(...) is portable across SQLite (gem tests) and PostgreSQL (hosts).
    def sql_calendar_date(column)
      Arel.sql("DATE(#{column})")
    end

    def normalize_sql_date(value)
      case value
      when Date then value
      when Time, DateTime, ActiveSupport::TimeWithZone then value.to_date
      else Date.parse(value.to_s)
      end
    end

    def counts_by_calendar_date(scope, column: "#{scope.klass.table_name}.created_at")
      scope.group(sql_calendar_date(column)).count.transform_keys { |key| normalize_sql_date(key) }
    end

    def sums_by_calendar_date(scope, field, column: "#{scope.klass.table_name}.created_at")
      scope.group(sql_calendar_date(column)).sum(field).transform_keys { |key| normalize_sql_date(key) }
    end

    def grouped_daily_counts(scope, *group_columns, column: "#{scope.klass.table_name}.created_at")
      scope.group(*group_columns, sql_calendar_date(column)).count.transform_keys do |key|
        *identity, date = Array(key)
        [*identity, normalize_sql_date(date)]
      end
    end

    # Fail closed: missing root yields no rows instead of every tenant's runs.
    # Binding the context lets filter option lambdas (which receive no args from
    # Recording Studio Admin) reuse the same root scope for dropdown values.
    def runs_scope(context = admin_context)
      bind_admin_context!(context) if context
      root_id = context&.root_recording&.id
      return RecordingStudioAI::Run.none if root_id.blank?

      RecordingStudioAI::Run.where(root_recording_id: root_id)
    end

    def tool_scope(context = admin_context)
      RecordingStudioAI::CustomToolInvocation.joins(:run).merge(runs_scope(context))
    end

    def attempts_scope(context = admin_context)
      RecordingStudioAI::Attempt.joins(:run).merge(runs_scope(context))
    end

    def responses_scope(context = admin_context)
      bind_admin_context!(context) if context
      root_id = context&.root_recording&.id
      return RecordingStudioAI::Response.none if root_id.blank?

      run_ids = RecordingStudioAI::Run.where(root_recording_id: root_id).select(:id)
      attempt_ids = RecordingStudioAI::Attempt.where(run_id: run_ids).select(:id)
      batch_item_ids = RecordingStudioAI::BatchItem.where(run_id: run_ids).select(:id)

      RecordingStudioAI::Response.includes(attempt: :run, batch_item: :run).where(
        "recording_studio_ai_responses.attempt_id IN (:attempt_ids) OR " \
        "recording_studio_ai_responses.batch_item_id IN (:batch_item_ids)",
        attempt_ids: attempt_ids,
        batch_item_ids: batch_item_ids
      )
    end

    def run_distinct_values(column)
      runs_scope.distinct.order(column).pluck(column).compact_blank
    end

    def run_present_distinct_values(column)
      runs_scope.where.not(column => nil).distinct.order(column).pluck(column).compact_blank
    end

    def attempt_distinct_values(column)
      attempts_scope.distinct.order(column).pluck(column).compact_blank
    end

    def attempt_present_distinct_values(column)
      attempts_scope.where.not(column => [nil, ""]).distinct.order(column).pluck(column).compact_blank
    end

    def tool_distinct_values(column)
      tool_scope.distinct.order(column).pluck(column).compact_blank
    end

    def response_distinct_values(column)
      responses_scope.distinct.order(column).pluck(column).compact_blank
    end

    def attempt_kind_series(relation, date_range:, field: "recording_studio_ai_attempts.created_at", bucket: :day)
      bucket = bucket.to_sym
      buckets = attempt_kind_bucket_keys(date_range, bucket)
      counts = attempt_kind_counts(relation, field, bucket)

      RecordingStudioAI::Attempt::KINDS.values.filter_map do |kind|
        next unless counts.keys.any? { |count_kind, _bucket| count_kind == kind }

        { name: attempt_kind_label(kind), data: attempt_kind_data(kind, buckets, counts, bucket) }
      end
    end

    def attempt_kind_label(kind)
      ATTEMPT_KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)
    end

    def attempt_kind_counts(relation, field, bucket)
      relation.reorder(nil).pluck(:kind, Arel.sql(field)).each_with_object(Hash.new(0)) do |row, counts|
        kind, created_at = row
        next if created_at.blank?

        counts[[kind.to_s, attempt_kind_bucket_key(created_at, bucket)]] += 1
      end
    end

    def attempt_kind_data(kind, buckets, counts, bucket)
      buckets.map do |bucket_key|
        { x: attempt_kind_bucket_label(bucket_key, bucket), y: counts.fetch([kind, bucket_key], 0) }
      end
    end

    def attempt_kind_bucket_keys(date_range, bucket)
      return [] unless date_range && date_range.start_date && date_range.end_date

      start_at = attempt_kind_bucket_key(date_range.start_date.beginning_of_day, bucket)
      end_at = attempt_kind_bucket_key(date_range.end_date.end_of_day, bucket)
      Enumerator.produce(start_at) { |value| value + attempt_kind_bucket_step(bucket) }
                .take_while { |value| value <= end_at }
    end

    def attempt_kind_bucket_step(bucket)
      { hour: 1.hour, day: 1.day, week: 1.week, month: 1.month, year: 1.year }.fetch(bucket, 1.day)
    end

    def attempt_kind_bucket_key(value, bucket)
      timestamp = value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)

      case bucket
      when :hour
        timestamp.beginning_of_hour
      when :week
        timestamp.beginning_of_week
      when :month
        timestamp.beginning_of_month
      when :year
        timestamp.beginning_of_year
      else
        timestamp.to_date
      end
    end

    def attempt_kind_bucket_label(value, bucket)
      timestamp = value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)

      case bucket
      when :hour
        timestamp.strftime("%-l%P").strip
      when :week
        "Week of #{timestamp.strftime('%b %-d')}"
      when :month
        timestamp.strftime("%b")
      when :year
        timestamp.strftime("%Y")
      else
        timestamp.strftime("%b %-d")
      end
    end

    def p90_latency(scope)
      count = scope.count
      return 0 if count.zero?

      offset = [(count * 0.9).ceil - 1, 0].max
      scope.order(:latency_ms).offset(offset).limit(1).pick(:latency_ms).to_i
    end

    def daily_p90_latency_series(scope, range: 30.days.ago..Time.current)
      rows = scope.where(created_at: range).pluck(:created_at, :latency_ms)
      rows.group_by { |created_at, _latency_ms| created_at.to_date }.sort_by(&:first).map do |date, day_rows|
        { x: date.strftime("%b %-d"), y: percentile_latency(day_rows.map(&:last), percentile: 0.9) }
      end
    end

    def percentile_latency(latencies, percentile:)
      values = latencies.compact.map(&:to_i).sort
      return 0 if values.empty?

      values[(values.length * percentile).ceil - 1]
    end

    def latency_rows(context, dimension:)
      date_range = latency_date_range(context, dimension: dimension)
      runs = runs_scope(context).where(created_at: date_range).where.not(latency_ms: nil)
      latency_rows_for_runs(runs, dimension: dimension, date_range: date_range)
    end

    def latency_chart_rows(context, dimension:, range: 30.days.ago..Time.current, limit: 5)
      memoize_widget([:latency_chart_rows, context.object_id, dimension, range.begin.to_f, range.end.to_f, limit]) do
        latency_rows_for_runs(
          runs_scope(context).where(created_at: range).where.not(latency_ms: nil),
          dimension: dimension
        ).first(limit)
      end
    end

    def latency_rows_for_runs(runs, dimension:, date_range: nil)
      grouped_latencies = runs.pluck(:resolved_model, :prompt_namespace, :prompt_name_snapshot, :prompt_key,
                                     :prompt_version, :latency_ms, :created_at).group_by do |row|
        latency_row_group_key(row, dimension: dimension)
      end

      grouped_latencies.map do |identity, rows|
        latencies = rows.map { |row| row[5] }
        LatencyRow.new(
          identity.fetch(:name),
          latencies.length,
          latency_calls_series(rows, date_range: date_range),
          percentile_latency(latencies, percentile: 0.5),
          percentile_latency(latencies, percentile: 0.9),
          (latencies.sum.to_f / latencies.length).round,
          latencies.max,
          identity[:prompt_namespace],
          identity[:prompt_key],
          identity[:prompt_version],
          identity[:resolved_model]
        )
      end.sort_by { |row| [-row.p90_latency_ms, row.name] }
    end

    def latency_row_group_key(row, dimension:)
      model, prompt_namespace, prompt_name, prompt_key, prompt_version, = row
      if dimension == :model
        { name: model.presence || "Unknown model", resolved_model: model.presence }
      else
        name = if prompt_name.present?
                 "#{prompt_name}#{" v#{prompt_version}" if prompt_version.present?}"
               else
                 prompt_key.presence || "No prompt"
               end
        {
          name: name,
          prompt_namespace: prompt_namespace,
          prompt_key: prompt_key,
          prompt_version: prompt_version
        }
      end
    end

    def latency_calls_series(rows, date_range:)
      return [] unless date_range&.begin && date_range.end

      daily_counts = rows.each_with_object(Hash.new(0)) do |row, counts|
        created_at = row.last
        next if created_at.blank?

        counts[created_at.to_date] += 1
      end

      (date_range.begin.to_date..date_range.end.to_date).map do |date|
        { x: date.strftime("%b %-d"), y: daily_counts.fetch(date, 0) }
      end
    end

    def latency_prompt_calls_path(context, row)
      latency_calls_path(
        context,
        screen: AdminScreens::RecordingStudioAILatencyByPromptScreen,
        prompt: row.prompt_key,
        prompt_namespace: row.prompt_namespace,
        prompt_version: row.prompt_version
      )
    end

    def latency_model_calls_path(context, row)
      latency_calls_path(
        context,
        screen: AdminScreens::RecordingStudioAILatencyByModelScreen,
        model: row.resolved_model
      )
    end

    def latency_calls_path(context, screen:, **filters)
      range_query = date_range_query(context, screen: screen)
      "/admin/screens/ai_calls?#{range_query.merge(filters.compact).to_query}"
    end

    def attempt_error_code_column_visible?(context = admin_context)
      values = Array(context&.filter_value(:status)).map(&:to_s)
      return true if values.include?("failed")

      params = context&.params || {}
      Array(params[:attempt_status] || params["attempt_status"]).map(&:to_s).include?("failed")
    end

    def latency_date_range(context, dimension:)
      prompt_created_at_range(latency_date_range_value(context, dimension: dimension))
    end

    def latency_date_range_value(context, dimension:)
      selected = context.filter_value(:date_range)
      return selected if selected

      latency_screen_for(dimension).filters.find { |filter| filter.key == :date_range }.normalize(context.params)
    end

    def latency_screen_for(dimension)
      if dimension == :model
        AdminScreens::RecordingStudioAILatencyByModelScreen
      else
        AdminScreens::RecordingStudioAILatencyByPromptScreen
      end
    end

    def latency_summary_p90(context, dimension:, previous: false)
      date_range = latency_date_range_value(context, dimension: dimension)
      date_range = previous_period_date_range(date_range) if previous
      latency_p90_for_range(context, date_range: date_range)
    end

    def latency_p90_for_range(context, date_range:)
      range = date_range.is_a?(Range) ? date_range : prompt_created_at_range(date_range)
      return 0 unless range

      p90_latency(runs_scope(context).where(created_at: range).where.not(latency_ms: nil))
    end

    def retry_rate_by_model_rows(scope, range: 30.days.ago..Time.current, limit: 3)
      runs = scope.where(created_at: range).where.not(resolved_model: nil)
      run_counts = runs.group(:resolved_model).count
      retried_run_counts = runs.where("retry_count > 0").group(:resolved_model).count

      run_counts.map do |model, count|
        [model, percentage(retried_run_counts.fetch(model, 0), count)]
      end.sort_by { |_model, rate| -rate }.first(limit)
    end

    def retry_rate_chart_rows(context, range: 30.days.ago..Time.current, limit: 3)
      memoize_widget([:retry_rate_chart_rows, context.object_id, range.begin.to_f, range.end.to_f, limit]) do
        retry_rate_by_model_rows(runs_scope(context), range: range, limit: limit)
      end
    end

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
        safety = definition.read_only ? "Read-only" : "Writes"
        safety = "#{safety}, destructive" if definition.destructive

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

    def prompt_rows(context)
      runs = runs_scope(context).where.not(prompt_key: nil)
      date_range = prompt_created_at_range(registered_prompts_date_range_value(context)) || (30.days.ago..Time.current)
      range_runs = runs.where(created_at: date_range)
      range_counts = range_runs.group(:prompt_namespace, :prompt_key, :prompt_version).count
      daily_counts = grouped_daily_counts(
        range_runs,
        :prompt_namespace,
        :prompt_key,
        :prompt_version,
        column: "#{RecordingStudioAI::Run.table_name}.created_at"
      )
      completed_counts = range_runs.where(status: "completed").group(:prompt_namespace, :prompt_key,
                                                                     :prompt_version).count
      error_counts = range_runs.where(status: %w[failed cancelled]).group(:prompt_namespace, :prompt_key,
                                                                          :prompt_version).count
      average_latencies = range_runs.group(:prompt_namespace, :prompt_key, :prompt_version).average(:latency_ms)
      average_input_tokens = range_runs.group(:prompt_namespace, :prompt_key, :prompt_version).average(:input_tokens)
      average_output_tokens = range_runs.group(:prompt_namespace, :prompt_key, :prompt_version).average(:output_tokens)

      RecordingStudioAI.prompts.all.map do |definition|
        key = [definition.namespace, definition.key, definition.version]
        total = range_counts.fetch(key, 0)

        PromptRow.new(
          definition.namespace,
          definition.key,
          definition.version,
          definition.name,
          definition.short_name,
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
      end.sort_by { |row| [-row.calls, row.namespace, row.key, row.version] }
    end

    def average_tokens(value)
      return "No data" if value.blank?

      number(value.round)
    end

    def top_prompt_call_rows(scope, range: 30.days.ago..Time.current, limit: 5)
      top = scope.where(created_at: range)
                 .where.not(prompt_key: nil)
                 .group(:prompt_namespace, :prompt_key)
                 .count
                 .sort_by { |_identity, count| -count }
                 .first(limit)
      return [] if top.empty?

      snapshot_names = latest_prompt_name_snapshots(scope, top.map(&:first))
      top.filter_map do |(namespace, key), calls|
        definition = RecordingStudioAI.prompts.fetch(namespace, key) if namespace.present?
        name = definition&.name || snapshot_names[[namespace, key]] || key
        [name, namespace, key, calls]
      end
    end

    def latest_prompt_name_snapshots(scope, identities)
      return {} if identities.empty?

      namespaces = identities.map(&:first).uniq
      keys = identities.map(&:last).uniq
      rows = scope.where(prompt_namespace: namespaces, prompt_key: keys)
                  .where.not(prompt_name_snapshot: [nil, ""])
                  .order(created_at: :desc)
                  .pluck(:prompt_namespace, :prompt_key, :prompt_name_snapshot)

      rows.each_with_object({}) do |(namespace, key, name), memo|
        memo[[namespace, key]] ||= name
      end
    end

    def prompt_chart_label(row)
      "#{row.name} (#{row.namespace}.#{row.key} v#{row.version})"
    end

    def prompt_calls_path(context, row)
      range_query = date_range_query(
        context,
        screen: AdminScreens::RecordingStudioAIRegisteredPromptsScreen
      )
      query = range_query.merge(
        prompt: row.key,
        prompt_namespace: row.namespace,
        prompt_version: row.version
      )
      "/admin/screens/ai_calls?#{query.to_query}"
    end

    def date_range_query(context, screen: AdminScreens::RecordingStudioAIRegisteredCustomToolsScreen)
      date_range = context.filter_value(:date_range) || screen.filters.find do |filter|
        filter.key == :date_range
      end.normalize(context.params)
      return { date_range_preset: :last_4_weeks } unless date_range&.start_date && date_range.end_date
      return { date_range_preset: date_range.preset_key } if date_range_matches_preset?(date_range)

      {
        start_date: date_range.start_date.iso8601,
        end_date: date_range.end_date.iso8601
      }
    end

    def date_range_matches_preset?(date_range)
      return false if date_range.preset_key.blank?
      return false unless defined?(RecordingStudioAdmin::Period)

      preset = RecordingStudioAdmin::Period.from_preset_key(date_range.preset_key)
      return false unless preset

      preset.start_date == date_range.start_date && preset.end_date == date_range.end_date
    end

    def registered_custom_tools_date_range_value(context)
      return context.filter_value(:date_range) if context.filter_value(:date_range)

      screen = AdminScreens::RecordingStudioAIRegisteredCustomToolsScreen
      screen.filters.find { |filter| filter.key == :date_range }.normalize(context.params)
    end

    def registered_prompts_date_range_value(context)
      return context.filter_value(:date_range) if context.filter_value(:date_range)

      screen = AdminScreens::RecordingStudioAIRegisteredPromptsScreen
      screen.filters.find { |filter| filter.key == :date_range }.normalize(context.params)
    end

    def previous_period_date_range(date_range)
      return unless date_range.respond_to?(:start_date) && date_range.respond_to?(:end_date)
      return unless date_range.start_date && date_range.end_date

      span_days = (date_range.end_date - date_range.start_date).to_i + 1
      previous_end = date_range.start_date - 1.day
      previous_start = previous_end - (span_days - 1).days
      DateRangeWindow.new(previous_start, previous_end, nil)
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

    def provider_rows(context)
      date_range = 30.days.ago.beginning_of_day..Time.current
      range_runs = runs_scope(context)
                   .where(created_at: date_range)
                   .where.not(resolved_provider: [nil, ""])
      call_counts = range_runs.group(:resolved_provider).count
      daily_counts = grouped_daily_counts(
        range_runs,
        :resolved_provider,
        column: "#{RecordingStudioAI::Run.table_name}.created_at"
      )

      rows = RecordingStudioAI.configuration.providers.map do |key, provider|
        provider_key = key.to_s
        ProviderRow.new(
          provider_key,
          provider.class.name.demodulize,
          provider.respond_to?(:configured?) ? provider.configured? : false,
          RecordingStudioAI.models.for_provider(key).length,
          call_counts.fetch(provider_key, 0),
          (date_range.begin.to_date..date_range.end.to_date).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([provider_key, date], 0) }
          end
        )
      end
      rows.sort_by { |row| [-row.calls, row.key] }
    end

    def model_rows(context)
      date_range = 30.days.ago.beginning_of_day..Time.current
      range_runs = runs_scope(context)
                   .where(created_at: date_range)
                   .where.not(resolved_model: [nil, ""])
      call_counts = range_runs.group(:resolved_provider, :resolved_model).count
      daily_counts = grouped_daily_counts(
        range_runs,
        :resolved_provider,
        :resolved_model,
        column: "#{RecordingStudioAI::Run.table_name}.created_at"
      )

      rows = RecordingStudioAI.models.all.map do |definition|
        provider_key = definition.provider.to_s
        model_key = definition.model
        ModelRow.new(
          provider_key,
          model_key,
          parameter_default_label(definition, :temperature),
          parameter_default_label(definition, :verbosity),
          parameter_default_label(definition, :reasoning_effort),
          definition.delivery.fetch(:streaming, false),
          definition.delivery.fetch(:structured_output, false),
          definition.delivery.fetch(:batch, false),
          definition.tools.map(&:to_s).join(", "),
          definition.modalities.fetch(:input, []).map(&:to_s).join(", "),
          definition.modalities.fetch(:output, []).map(&:to_s).join(", "),
          call_counts.fetch([provider_key, model_key], 0),
          (date_range.begin.to_date..date_range.end.to_date).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([provider_key, model_key, date], 0) }
          end
        )
      end
      filter_model_rows_by_provider(rows, context).sort_by { |row| [-row.calls, row.provider, row.model] }
    end

    def registered_provider_keys
      RecordingStudioAI.configuration.providers.keys.map(&:to_s)
    end

    def registered_models_path(context, provider:)
      "#{context.admin_screen_path('registered_models')}?#{{ provider: provider }.to_query}"
    end

    def filter_model_rows_by_provider(rows, context)
      return rows unless context.respond_to?(:filter_value)

      provider = context.filter_value(:provider).to_s.presence
      return rows if provider.blank?

      rows.select { |row| row.provider.to_s == provider }
    end

    def parameter_default_label(definition, name)
      return "—" unless definition.supports_parameter?(name)

      value = definition.parameter(name)&.fetch(:default, nil)
      value.nil? ? "Supported" : value.to_s
    end

    def top_provider_call_rows(context, range: 30.days.ago..Time.current, limit: 5)
      counts = runs_scope(context)
               .where(created_at: range)
               .where.not(resolved_provider: [nil, ""])
               .group(:resolved_provider)
               .count

      rows = RecordingStudioAI.configuration.providers.keys.map do |key|
        [key.to_s, counts.fetch(key.to_s, 0)]
      end
      rows.sort_by { |_key, calls| -calls }.first(limit)
    end

    def top_model_call_rows(context, range: 30.days.ago..Time.current, limit: 5)
      counts = runs_scope(context)
               .where(created_at: range)
               .where.not(resolved_model: [nil, ""])
               .group(:resolved_provider, :resolved_model)
               .count

      rows = RecordingStudioAI.models.all.map do |definition|
        [
          definition.provider.to_s,
          definition.model,
          definition.display_name,
          counts.fetch([definition.provider.to_s, definition.model], 0)
        ]
      end
      rows.sort_by { |_provider, _model, _name, calls| -calls }.first(limit)
    end

    def number(value)
      ActionController::Base.helpers.number_with_delimiter(value.to_i)
    end

    def duration(milliseconds)
      return "No data" if milliseconds.blank?

      milliseconds.to_f >= 1_000 ? format("%.1fs", milliseconds.to_f / 1_000) : "#{milliseconds.to_i}ms"
    end

    def mini_chart(series)
      render_flatpack(
        FlatPack::Chart::Component.new(
          series: [{ name: "Calls", data: series }],
          type: :line,
          height: 64,
          card: false,
          class: "h-16 w-36",
          options: {
            chart: { toolbar: { show: false }, sparkline: { enabled: true } },
            colors: ["#000000"],
            stroke: { curve: "smooth", width: 2 },
            tooltip: { theme: "light" },
            xaxis: { labels: { show: false } },
            yaxis: { min: 0, labels: { show: false } },
            grid: { show: false }
          }
        )
      )
    end

    def custom_tool_definition_modal(row)
      definition = RecordingStudioAI.tools.fetch(row.key, version: row.version)
      definition_modal(
        modal_id: "custom-tool-definition-#{row.key}-#{row.version}",
        title: "#{definition.name} v#{definition.version}",
        trigger_text: "#{row.name} v#{row.version}",
        aria_label: "Show definition for #{row.name}",
        fields: {
          "Description" => definition.description,
          "Use when" => definition.use_when,
          "Do not use when" => definition.do_not_use_when,
          "Returns" => definition.returns,
          "Executor" => definition.executor_label,
          "Safety" => "#{definition.read_only ? 'Read only' : 'Writes'}; destructive: #{definition.destructive ? 'yes' : 'no'}; confirmation: #{definition.requires_confirmation ? 'required' : 'not required'}; idempotent: #{definition.idempotent ? 'yes' : 'no'}"
        }
      )
    end

    def prompt_definition_modal(row)
      definition = RecordingStudioAI.prompts.fetch(row.namespace, row.key, version: row.version)
      definition_modal(
        modal_id: "registered-prompt-definition-#{row.namespace}-#{row.key}-#{row.version}",
        title: "#{definition.name} v#{definition.version}",
        trigger_text: "#{row.name} v#{row.version}",
        aria_label: "Show definition for #{row.name}",
        fields: {
          "Namespace" => definition.namespace,
          "Key" => definition.key,
          "Short name" => definition.short_name,
          "Description" => definition.description,
          "Inputs" => definition.inputs.presence&.join(", ") || "None",
          "Tools" => prompt_tool_labels(definition),
          "Defaults" => definition.defaults.presence&.map { |key, value| "#{key}: #{value}" }&.join(", ") || "None",
          "Prompt" => prompt_messages_markup(definition.messages)
        }
      )
    end

    def prompt_tool_labels(definition)
      return "None" if definition.tools.empty?

      definition.tools.map do |tool|
        tool[:version] ? "#{tool.fetch(:key)} v#{tool[:version]}" : tool.fetch(:key)
      end.join(", ")
    end

    def prompt_messages_markup(messages)
      helpers = ActionController::Base.helpers
      helpers.content_tag(:div, class: "grid gap-3") do
        helpers.safe_join(messages.map { |message| prompt_message_card(message) })
      end
    end

    def prompt_message_card(message)
      render_flatpack(FlatPack::Card::Component.new) do |card|
        card.header do
          render_flatpack(
            FlatPack::PageTitle::Component.new(
              title: message.fetch(:role).to_s.humanize,
              variant: :h4,
              class: "mb-0 pb-0"
            )
          )
        end
        card.body do
          render_flatpack(
            FlatPack::CodeBlock::Component.new(
              title: "Message",
              language: "text",
              code: message.fetch(:content).to_s,
              separated: false
            )
          )
        end
      end
    end

    def definition_modal(modal_id:, title:, trigger_text:, aria_label:, fields:)
      helpers = ActionController::Base.helpers
      body = helpers.content_tag(:dl, class: "grid gap-4 text-sm") do
        helpers.safe_join(fields.map do |label, value|
          helpers.content_tag(:div) do
            helpers.safe_join([
                                helpers.content_tag(:dt, label,
                                                    class: "text-sm text-[var(--surface-muted-content-color)]"),
                                helpers.content_tag(:dd, value)
                              ])
          end
        end)
      end
      trigger = render_flatpack(
        FlatPack::Button::Component.new(
          text: trigger_text,
          style: :ghost,
          size: :sm,
          type: "button",
          data: { modal_id: modal_id },
          aria: { label: aria_label }
        )
      )
      modal = render_flatpack(
        FlatPack::Modal::Component.new(id: modal_id, title: title, size: :lg)
      ) do |component|
        component.body { body }
      end
      helpers.safe_join([trigger, modal])
    end

    def render_flatpack(component, &)
      html = component_view_context.render(component, &)
      html.respond_to?(:html_safe) ? html : html.to_s.html_safe
    end

    def component_view_context
      context = admin_context
      return context.view_context if context.respond_to?(:view_context) && context.view_context
      return context.controller.view_context if context&.controller.respond_to?(:view_context)

      fallback_component_view_context
    end

    def fallback_component_view_context
      controller = ActionController::Base.new
      request = ActionDispatch::Request.empty
      controller.set_request!(request) if controller.respond_to?(:set_request!)
      controller.view_context
    end

    def percentage(part, whole)
      return 0.0 if whole.to_i <= 0

      ((part.to_f / whole.to_f) * 100).round(1)
    end

    def percentage_change_label(current:, previous:)
      change =
        if previous.to_i <= 0
          current.to_i.positive? ? 100.0 : 0.0
        else
          (((current.to_f - previous.to_f) / previous.to_f) * 100).round(1)
        end

      formatted = (change % 1).zero? ? change.to_i.to_s : format("%.1f", change)
      sign = change.positive? ? "+" : ""
      "#{sign}#{formatted}%"
    end

    def this_week_range(reference_time: Time.current)
      reference_time.beginning_of_week..reference_time
    end

    def previous_week_range(reference_time: Time.current)
      current_week_start = reference_time.beginning_of_week
      (current_week_start - 1.week)..(current_week_start - 1.second)
    end

    def trailing_weeks_range(weeks_back:, reference_time: Time.current)
      current_week_start = reference_time.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      start_week..reference_time
    end

    def weekly_calls_series(scope, weeks_back: 12, series_name: "AI calls")
      current_week_start = Time.current.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      range = start_week..Time.current
      daily_counts = counts_by_calendar_date(scope.where(created_at: range))

      [{
        name: series_name,
        data: week_starts(start_week, current_week_start).map do |week_start|
          {
            x: week_start.strftime("%b %-d"),
            y: sum_daily_counts_for_week(daily_counts, week_start)
          }
        end
      }]
    end

    def weekly_token_series(scope, weeks_back: 12, series_name: "Token usage")
      current_week_start = Time.current.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      range = start_week..Time.current
      daily_sums = sums_by_calendar_date(scope.where(created_at: range), :total_tokens)

      [{
        name: series_name,
        data: week_starts(start_week, current_week_start).map do |week_start|
          {
            x: week_start.strftime("%b %-d"),
            y: sum_daily_counts_for_week(daily_sums, week_start)
          }
        end
      }]
    end

    def week_starts(start_week, current_week_start)
      starts = []
      cursor = start_week
      while cursor <= current_week_start
        starts << cursor
        cursor += 1.week
      end
      starts
    end

    def sum_daily_counts_for_week(daily_values, week_start)
      week_end = [week_start.to_date + 6, Time.current.to_date].min
      (week_start.to_date..week_end).sum { |date| daily_values.fetch(date, 0).to_i }
    end

    def top_model_token_rows(scope, range:, limit: 5)
      scope.where(created_at: range)
           .where.not(total_tokens: nil)
           .group(:resolved_model)
           .sum(:total_tokens)
           .sort_by { |_model, total_tokens| -total_tokens.to_i }
           .first(limit)
    end

    def top_model_token_chart_rows(context, range: 30.days.ago..Time.current, limit: 5)
      memoize_widget([:top_model_token_chart_rows, context.object_id, range.begin.to_f, range.end.to_f, limit]) do
        top_model_token_rows(runs_scope(context), range: range, limit: limit)
      end
    end

    def model_token_totals(runs)
      memoize_widget([:model_token_totals, runs.object_id]) do
        runs.reorder(nil)
            .where.not(total_tokens: nil)
            .group(:resolved_model)
            .sum(:total_tokens)
            .each_with_object(Hash.new(0)) do |(model, total_tokens), totals|
              totals[model.presence || "Unknown"] += total_tokens.to_i
            end
            .sort_by { |model, total_tokens| [-total_tokens, model.to_s.downcase] }
      end
    end

    def token_total_for_range(context, date_range:)
      range = prompt_created_at_range(date_range)
      return 0 unless range

      runs_scope(context).where.not(total_tokens: nil).where(created_at: range).sum(:total_tokens).to_i
    end

    def run_filtered_screen_path(context, screen_key, run)
      query = date_range_query(context, screen: AdminScreens::RecordingStudioAICallsScreen).merge(run_id: run.id)
      "#{context.admin_screen_path(screen_key)}?#{query.to_query}"
    end

    def top_model_call_volume_rows(context, range: 30.days.ago..Time.current, limit: 5)
      memoize_widget([:top_model_call_volume_rows, context.object_id, range.begin.to_f, range.end.to_f, limit]) do
        model_call_totals(runs_scope(context).where(created_at: range)).first(limit)
      end
    end

    def model_call_totals(runs)
      memoize_widget([:model_call_totals, runs.object_id]) do
        runs.reorder(nil)
            .group(:resolved_model)
            .count
            .each_with_object(Hash.new(0)) do |(model, count), totals|
              totals[model.presence || "Unknown"] += count.to_i
            end
            .sort_by { |model, count| [-count, model.to_s.downcase] }
      end
    end

    def token_change_label(scope, current_range:, previous_range:)
      current = scope.where(created_at: current_range).where.not(total_tokens: nil).sum(:total_tokens)
      previous = scope.where(created_at: previous_range).where.not(total_tokens: nil).sum(:total_tokens)
      percentage_change_label(current: current, previous: previous)
    end

    def warning_items(scope)
      now = Time.current
      last_day = scope.where(created_at: 24.hours.ago..now)
      previous_week = scope.where(created_at: 8.days.ago.beginning_of_day..1.day.ago.end_of_day)

      warnings = []

      usage_today = scope.where(created_at: now.beginning_of_day..now).count
      baseline_daily = counts_by_calendar_date(previous_week).values
      baseline_average = baseline_daily.empty? ? 0 : (baseline_daily.sum.to_f / baseline_daily.size)
      if usage_today >= [20, (baseline_average * 1.8).ceil].max
        warnings << {
          text: "Unusually high usage today: #{number(usage_today)} calls",
          icon: "arrow-trending-up"
        }
      end

      failed_last_day = last_day.where(status: "failed").count
      failed_previous_week = previous_week.where(status: "failed").count
      previous_failure_rate = percentage(failed_previous_week, previous_week.count)
      current_failure_rate = percentage(failed_last_day, last_day.count)
      if failed_last_day >= 3 && current_failure_rate >= [12.0, previous_failure_rate * 1.7].max
        warnings << {
          text: "Error spike: #{current_failure_rate}% failures in the last 24h",
          icon: "shield-exclamation"
        }
      end

      expensive_last_day = last_day.where("resolved_model ~* ?", EXPENSIVE_MODEL_MATCHER.source).count
      expensive_share = percentage(expensive_last_day, last_day.count)
      if expensive_last_day >= 3 || expensive_share >= 35.0
        warnings << {
          text: "Expensive model usage elevated: #{expensive_share}% in the last 24h",
          icon: "currency-dollar"
        }
      end

      warnings
    end
  end
end
