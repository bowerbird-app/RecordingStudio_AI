# frozen_string_literal: true

# BUG: warning_items matched expensive models with Postgres-only "~*", so the SQLite unit
# database raised before any warning list was returned. expensive_model_count keeps "~*"
# on PostgreSQL and matches EXPENSIVE_MODEL_MATCHER in Ruby on other adapters.
# BUG: normalize_sql_date checked Date before DateTime. DateTime inherits Date, so that
# branch never ran and a DateTime was returned unchanged.

require "test_helper"
require "action_controller"
require "view_component"
require "recording_studio_ai/admin/recording_studio_ai_widgets"
require "recording_studio_ai/admin/runs_health"
require "recording_studio_ai/admin/metric_read"

module AdminWidgetCoverageFilters
  class Filter
    def initialize(key)
      @key = key
    end

    attr_reader :key

    def normalize(params)
      values = params.to_h.transform_keys(&:to_sym)
      return date_window(values) if key == :date_range

      values[key]
    end

    private

    def date_window(values)
      return if values[:start_date].blank? || values[:end_date].blank?

      AdminScreens::RecordingStudioAIWidgets::DateRangeWindow.new(
        Date.iso8601(values[:start_date].to_s),
        Date.iso8601(values[:end_date].to_s),
        values[:date_range_preset]&.to_sym
      )
    end
  end
end

module AdminWidgetCoverageScreens
  NAMES = {
    "RecordingStudioAICallsScreen" => [:date_range],
    "RecordingStudioAIRegisteredPromptsScreen" => [:date_range],
    "RecordingStudioAIRegisteredCustomToolsScreen" => [:date_range],
    "RecordingStudioAILatencyByModelScreen" => [:date_range],
    "RecordingStudioAILatencyByPromptScreen" => [:date_range],
    "RecordingStudioAIRunsHealthScreen" => %i[date_range group_by profile status stuck]
  }.freeze

  def self.install!
    NAMES.each do |name, keys|
      next if AdminScreens.const_defined?(name, false)

      filters = keys.map { |key| AdminWidgetCoverageFilters::Filter.new(key) }
      screen = Class.new { define_singleton_method(:filters) { filters } }
      AdminScreens.const_set(name, screen)
    end
  end
end

AdminWidgetCoverageScreens.install!

module AdminWidgetCoverageFlatPack
  class LinkComponent < ViewComponent::Base
    def initialize(href:, **_rest)
      super()
      @href = href
    end

    def call
      helpers.content_tag(:a, content, href: @href)
    end
  end

  class CardComponent < ViewComponent::Base
    def initialize(**_rest)
      super()
    end

    def header(**_rest)
      @header = yield
    end

    def body(**_rest)
      @body = yield
    end

    def call
      content
      helpers.safe_join([
                          helpers.content_tag(:div, @header, class: "label"),
                          helpers.content_tag(:div, @body, class: "value")
                        ])
    end
  end

  class ModalComponent < ViewComponent::Base
    def initialize(id:, title:, **_rest)
      super()
      @id = id
      @title = title
    end

    def body
      @body = yield
    end

    def call
      content
      helpers.content_tag(:section, id: @id) do
        helpers.safe_join([helpers.content_tag(:h2, @title), @body])
      end
    end
  end

  class ChartComponent < ViewComponent::Base
    def initialize(series:, **_rest)
      super()
      raise ArgumentError, "series must be an Array or Hash" unless series.is_a?(Array) || series.is_a?(Hash)

      @series = series
    end

    def call
      names = @series.filter_map { |item| item[:name] || item["name"] }
      points = @series.flat_map { |item| Array(item[:data] || item["data"]) }
      helpers.content_tag(:div, class: "chart") do
        helpers.safe_join([
                            helpers.content_tag(:span, names.join(",")),
                            *points.map { |point| helpers.content_tag(:span, point[:x] || point["x"]) }
                          ])
      end
    end
  end

  class CodeBlockComponent < ViewComponent::Base
    def initialize(title:, code:, **_rest)
      super()
      @title = title
      @code = code
    end

    def call
      helpers.safe_join([helpers.content_tag(:h3, @title), helpers.content_tag(:pre, @code)])
    end
  end
end

class AdminWidgetCoveragePeriod
  attr_reader :start_date, :end_date, :preset_key

  def initialize(start_date:, end_date:, preset_key:)
    @start_date = start_date
    @end_date = end_date
    @preset_key = preset_key
  end

  def self.from_preset_key(key)
    return if key.blank?

    case key.to_sym
    when :today
      new(start_date: Date.current, end_date: Date.current, preset_key: :today)
    when :last_30_days
      new(start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 1, 30), preset_key: :last_30_days)
    else
      new(start_date: Date.current - 6, end_date: Date.current, preset_key: key.to_sym)
    end
  end
end

class AdminWidgetCoverageTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Data.define(:id)
  Window = AdminScreens::RecordingStudioAIWidgets::DateRangeWindow
  Widgets = AdminScreens::RecordingStudioAIWidgets
  Health = RecordingStudioAI::Admin::RunsHealth
  MetricsRead = RecordingStudioAI::Admin::MetricRead
  Copy = RecordingStudioAI::Copy

  module SqliteDayAdapter
    module_function

    def truncate_sql(_connection, table, column, interval, _timezone)
      expression = "#{table}.#{column}"
      case interval.to_s
      when "hour" then "strftime('%Y-%m-%d %H:00:00', #{expression})"
      when "month" then "strftime('%Y-%m-01', #{expression})"
      when "year" then "strftime('%Y-01-01', #{expression})"
      else "date(#{expression})"
      end
    end

    def truncate_date_sql(connection, table, column, interval)
      truncate_sql(connection, table, column, interval, nil)
    end
  end

  class AdminContext
    def initialize(root:, actor:, filters: {}, **options)
      @root = root
      @filters = filters.transform_keys(&:to_sym)
      @params = options.fetch(:params, {})
      @view_context = options[:view_context]
      @controller = options[:controller]
      @actor = actor
    end

    attr_reader :params, :view_context, :controller

    def root_recording
      @root
    end

    def access_recording
      @root
    end

    def current_actor
      @actor
    end

    def filter_value(key)
      @filters[key.to_sym] if @filters.key?(key.to_sym)
    end

    def admin_screen_path(screen_key)
      "/admin/screens/#{screen_key}"
    end
  end

  class ColumnHost
    Column = Struct.new(:key)

    def columns
      [Column.new(:status), Column.new(:error_code)]
    end

    def default_column_keys
      %i[status error_code]
    end
  end

  class PluckRelation
    def initialize(rows)
      @rows = rows
    end

    def pluck(*)
      @rows
    end

    def none
      self.class.new([])
    end
  end

  def setup
    super
    @previous_time_zone = Time.zone
    Time.zone = "UTC"
    @configuration = isolate_configuration!
    @configuration.attribution_validator = ->(**) {}
    @actor = Actor.new(id: 42)
    isolate_prompt_registry!
    isolate_tools_registry!
    install_flatpack_fakes!
    RecordingStudioAI::Metrics.register!
    Widgets.clear_admin_context!
  end

  def teardown
    remove_flatpack_fakes!
    restore_prompt_registry!
    Widgets.clear_admin_context!
    Time.zone = @previous_time_zone if instance_variable_defined?(:@previous_time_zone)
    super
  end

  def test_duration_percentage_week_ranges_and_sql_dates
    assert_equal "0ms", Widgets.duration(0)
    assert_equal "250ms", Widgets.duration(250)
    assert_equal "7200.0s", Widgets.duration(2.hours.in_milliseconds)
    assert_equal Copy.t("common.no_data"), Widgets.duration(nil)

    assert_equal 0.0, Widgets.percentage(4, 0)
    assert_equal 25.0, Widgets.percentage(1, 4)
    assert_equal "0%", Widgets.percentage_change_label(current: 0, previous: 0)
    assert_equal "+100%", Widgets.percentage_change_label(current: 4, previous: 0)
    assert_equal "+50%", Widgets.percentage_change_label(current: 15, previous: 10)
    assert_equal "-50%", Widgets.percentage_change_label(current: 5, previous: 10)
    assert_equal "0%", Widgets.percentage_change_label(current: 8, previous: 8)
    assert_equal "-66.7%", Widgets.percentage_change_label(current: 1, previous: 3)

    reference = Time.zone.parse("2026-05-06 15:00:00")
    this_week = Widgets.this_week_range(reference_time: reference)
    previous_week = Widgets.previous_week_range(reference_time: reference)
    trailing = Widgets.trailing_weeks_range(weeks_back: 3, reference_time: reference)
    assert_equal reference.beginning_of_week, this_week.begin
    assert_equal reference, this_week.end
    assert_equal reference.beginning_of_week - 1.week, previous_week.begin
    assert_equal reference.beginning_of_week - 1.second, previous_week.end
    assert_equal (reference.beginning_of_week - 2.weeks).beginning_of_week, trailing.begin
    assert_equal reference, trailing.end

    day = Date.new(2026, 5, 4)
    assert_equal day, Widgets.normalize_sql_date(day)
    assert_equal day, Widgets.normalize_sql_date(Time.utc(2026, 5, 4, 9, 0, 0))
    assert_equal day, Widgets.normalize_sql_date(Time.zone.parse("2026-05-04 09:00:00"))
    assert_equal day, Widgets.normalize_sql_date(DateTime.new(2026, 5, 4, 9, 0, 0))
    assert_equal day, Widgets.normalize_sql_date("2026-05-04")
    assert_raises(Date::Error) { Widgets.normalize_sql_date(nil) }

    root = create_recording_id
    create_run(root_id: root, status: "completed", tokens: 1, created_at: Time.zone.parse("2026-05-04 08:00:00"))
    create_run(root_id: root, status: "completed", tokens: 1, created_at: Time.zone.parse("2026-05-04 18:00:00"))
    create_run(root_id: root, status: "failed", tokens: 1, created_at: Time.zone.parse("2026-05-05 08:00:00"))
    counts = Widgets.grouped_daily_counts(RecordingStudioAI::Run.where(root_recording_id: root), :status)
    assert_equal 2, counts.fetch(["completed", day])
    assert_equal 1, counts.fetch(["failed", Date.new(2026, 5, 5)])
  end

  def test_date_range_query_preset_match_and_custom_range
    removed_period = hide_admin_period!
    custom = Window.new(Date.new(2026, 1, 2), Date.new(2026, 1, 5), nil)
    preset_looking = Window.new(Date.current, Date.current, :today)
    context = admin_context(filters: { date_range: custom })
    blank_context = admin_context(params: {})

    assert_equal({ start_date: "2026-01-02", end_date: "2026-01-05" }, Widgets.date_range_query(context))
    refute Widgets.date_range_matches_preset?(preset_looking)
    assert_equal({ date_range_preset: :last_4_weeks }, Widgets.date_range_query(blank_context))

    fallback = Health.default_date_range_window
    assert_equal :last_30_days, fallback.preset_key
    assert_equal Date.current, fallback.end_date
    assert_equal 29.days.ago.to_date, fallback.start_date
  ensure
    restore_admin_period!(removed_period)
  end

  def test_date_range_query_uses_a_matching_admin_period
    with_admin_period do
      period = RecordingStudioAdmin::Period.from_preset_key(:today)
      matched = Window.new(period.start_date, period.end_date, period.preset_key)
      shifted = Window.new(period.start_date - 2, period.end_date, period.preset_key)
      context = admin_context(filters: { date_range: matched })

      assert Widgets.date_range_matches_preset?(matched)
      assert_equal({ date_range_preset: :today }, Widgets.date_range_query(context))
      refute Widgets.date_range_matches_preset?(shifted)
      assert_equal(
        { start_date: shifted.start_date.iso8601, end_date: shifted.end_date.iso8601 },
        Widgets.date_range_query(admin_context(filters: { date_range: shifted }))
      )

      window = Health.default_date_range_window
      assert_equal Date.new(2020, 1, 1), window.start_date
      assert_equal Date.new(2020, 1, 30), window.end_date
      assert_equal :last_30_days, window.preset_key
    end
  end

  def test_attempt_columns_follow_the_failed_status_filter
    host = ColumnHost.new
    host.extend(Widgets::AttemptErrorCodeColumn)
    host.instance_variable_set(:@default_column_keys, %i[status error_code])
    failed = admin_context(filters: { status: "failed" }, params: {})
    completed = admin_context(filters: { status: "completed" }, params: { attempt_status: "completed" })

    Widgets.bind_admin_context!(failed)
    assert_equal %i[status error_code], host.default_column_keys
    assert_equal %i[status error_code], host.columns.map(&:key)

    Widgets.bind_admin_context!(completed)
    assert_equal [:status], host.default_column_keys
    assert_equal [:status], host.columns.map(&:key)
  ensure
    Widgets.clear_admin_context!
  end

  def test_site_and_attempt_distinct_values_follow_the_bound_root
    visible = create_recording_id
    hidden = create_recording_id
    visible_run = create_run(
      root_id: visible, status: "failed", tokens: 3, profile_key: "fast", resolved_model: "gpt-5"
    )
    hidden_run = create_run(
      root_id: hidden, status: "completed", tokens: 4, profile_key: nil, resolved_model: nil
    )
    create_run(root_id: visible, status: "completed", tokens: 1, profile_key: "")
    create_invocation(visible_run, tool_key: "visible-tool", status: "completed")
    create_invocation(hidden_run, tool_key: "hidden-tool", status: "failed")
    create_attempt(visible_run, kind: "primary", status: "failed", error_code: "timeout", provider: "openai")
    create_attempt(hidden_run, kind: "retry", status: "completed", error_code: "hidden-code", provider: "gemini")
    create_attempt(visible_run, kind: "fallback", status: "completed", error_code: "", provider: "openai")
    context = admin_context(root: Actor.new(id: visible))
    Widgets.bind_admin_context!(context)

    assert_equal %w[hidden-tool visible-tool], Widgets.site_tool_scope.pluck(:tool_key).sort
    assert_equal %w[completed failed], Widgets.site_run_distinct_values(:status)
    assert_equal ["fast"], Widgets.site_run_present_distinct_values(:profile_key)
    assert_equal %w[openai], Widgets.attempt_distinct_values(:provider)
    assert_equal ["timeout"], Widgets.attempt_present_distinct_values(:error_code)
    assert_includes Widgets.attempt_distinct_values(:kind), "primary"
    refute_includes Widgets.attempt_distinct_values(:kind), "retry"
  ensure
    Widgets.clear_admin_context!
  end

  def test_attempt_kind_buckets_and_series
    stamp = Time.zone.parse("2026-05-04 15:30:00")
    assert_equal stamp.beginning_of_hour, Widgets.attempt_kind_bucket_key(stamp, :hour)
    assert_equal stamp.beginning_of_week, Widgets.attempt_kind_bucket_key(stamp, :week)
    assert_equal stamp.beginning_of_month, Widgets.attempt_kind_bucket_key(stamp, :month)
    assert_equal stamp.beginning_of_year, Widgets.attempt_kind_bucket_key(stamp, :year)
    assert_equal stamp.to_date, Widgets.attempt_kind_bucket_key(stamp, :day)
    assert_equal stamp.to_date, Widgets.attempt_kind_bucket_key(stamp, :quarter)
    assert_equal Date.new(2026, 5, 4), Widgets.attempt_kind_bucket_key("2026-05-04 15:30:00", :day)

    assert_equal "3pm", Widgets.attempt_kind_bucket_label(stamp.beginning_of_hour, :hour)
    assert_equal Copy.t("common.week_of", date: "May 4"),
                 Widgets.attempt_kind_bucket_label(stamp.beginning_of_week, :week)
    assert_equal "May", Widgets.attempt_kind_bucket_label(stamp.beginning_of_month, :month)
    assert_equal "2026", Widgets.attempt_kind_bucket_label(stamp.beginning_of_year, :year)
    assert_equal "May 4", Widgets.attempt_kind_bucket_label(stamp, :day)
    assert_equal "May 4", Widgets.attempt_kind_bucket_label("2026-05-04", :quarter)
    assert_empty Widgets.attempt_kind_bucket_keys(Window.new(Date.new(2026, 5, 4), nil, nil), :day)

    root = create_recording_id
    run = create_run(root_id: root, status: "completed", tokens: 1, created_at: stamp)
    %w[primary retry fallback continuation].each_with_index do |kind, index|
      create_attempt(run, kind: kind, created_at: stamp + index.minutes)
    end
    range = Window.new(Date.new(2026, 5, 4), Date.new(2026, 5, 4), nil)
    series = Widgets.attempt_kind_series(run.attempts, date_range: range, bucket: :day)
    assert_equal(
      %w[primary retry fallback continuation].map { |kind| Widgets.attempt_kind_label(kind) },
      series.map { |entry| entry[:name] }
    )
    assert_equal([1, 1, 1, 1], series.map { |entry| series_total(entry[:data]) })

    hourly = Widgets.attempt_kind_series(run.attempts, date_range: range, bucket: :hour)
    primary = hourly.find { |entry| entry[:name] == Widgets.attempt_kind_label("primary") }
    assert_equal 1, primary[:data].find { |point| point[:x] == "3pm" }.fetch(:y)
  end

  def test_warning_items_reports_expensive_models_error_spikes_and_a_clean_scope
    root = create_recording_id
    expensive = %w[GPT-5 o1-mini gemini-2.5-pro].map do |model|
      create_run(root_id: root, status: "completed", tokens: 1, resolved_model: model)
    end
    failing = Array.new(3) do
      create_run(root_id: root, status: "failed", tokens: 1, resolved_model: "gpt-test")
    end
    calm = [create_run(root_id: root, status: "completed", tokens: 1, resolved_model: "gpt-test")]
    busy = Array.new(20) do
      create_run(root_id: root, status: "completed", tokens: 1, resolved_model: "gpt-test")
    end

    expensive_warnings = Widgets.warning_items(RecordingStudioAI::Run.where(id: expensive.map(&:id)))
    error_warnings = Widgets.warning_items(RecordingStudioAI::Run.where(id: failing.map(&:id)))
    calm_warnings = Widgets.warning_items(RecordingStudioAI::Run.where(id: calm.map(&:id)))
    busy_warnings = Widgets.warning_items(RecordingStudioAI::Run.where(id: busy.map(&:id)))

    assert_equal ["currency-dollar"], warning_icons(expensive_warnings)
    assert_equal Copy.t("admin.alerts.expensive_model", share: 100.0), expensive_warnings.first[:text]
    assert_equal ["shield-exclamation"], warning_icons(error_warnings)
    assert_equal Copy.t("admin.alerts.error_spike", rate: 100.0), error_warnings.first[:text]
    assert_empty calm_warnings
    assert_equal ["arrow-trending-up"], warning_icons(busy_warnings)
    assert_equal Widgets.high_usage_alert_text(20), busy_warnings.first[:text]
  end

  def test_definition_modal_renders_title_and_field_through_the_view_context
    view = Widgets.fallback_component_view_context
    assert_respond_to view, :render
    bound = admin_context(view_context: view)
    Widgets.bind_admin_context!(bound)
    assert_same view, Widgets.component_view_context

    controller = Object.new
    controller.define_singleton_method(:view_context) { view }
    Widgets.bind_admin_context!(admin_context(controller: controller))
    assert_same view, Widgets.component_view_context

    Widgets.clear_admin_context!
    html = Widgets.definition_modal(
      modal_id: "coverage-modal",
      title: "Coverage Title",
      trigger_text: "Open coverage",
      aria_label: "Show coverage",
      fields: { "Prompt Key" => "coverage_prompt" }
    ).to_s
    card = Widgets.definition_field_card(label: "Prompt Key", value: "coverage_prompt").to_s
    chart = Widgets.mini_chart([{ x: "May 2", y: 2 }]).to_s
    empty_chart = Widgets.mini_chart([]).to_s

    assert_includes html, "Coverage Title"
    assert_includes html, "coverage_prompt"
    assert_includes html, "Open coverage"
    assert_includes card, "Prompt Key"
    assert_includes card, "coverage_prompt"
    assert_includes chart, "May 2"
    assert_includes chart, Copy.t("common.calls")
    nil_chart = Widgets.mini_chart(nil).to_s
    assert_includes empty_chart, Copy.t("common.calls")
    assert_includes nil_chart, Copy.t("common.calls")
    refute_includes nil_chart, "May 2"
  ensure
    Widgets.clear_admin_context!
  end

  def test_prompt_rows_average_tokens_and_definition_markup
    root = create_recording_id
    register_tool!(key: :echo_tool, name: "Echo", read_only: true, destructive: false,
                   requires_confirmation: false, idempotent: true)
    register_tool!(key: :write_tool, name: "Write", read_only: false, destructive: true,
                   requires_confirmation: true, idempotent: false)
    register_prompt!(tools: [{ key: :echo_tool, version: 1 }, { key: :write_tool }])
    RecordingStudioAI.prompts.register(
      owner: nil, key: :unused_prompt, version: 1, name: "Unused Prompt",
      description: "No calls yet.", inputs: [:customer_name],
      messages: [{ role: :user, content: "Hello {{customer_name}}" }], tools: [], defaults: {}
    )
    create_run(
      root_id: root, status: "completed", tokens: 10, prompt_key: "coverage_prompt", prompt_version: 1,
      prompt_name_snapshot: "Coverage Prompt", latency_ms: 1_500, input_tokens: 100, output_tokens: 10
    )
    create_run(
      root_id: root, status: "failed", tokens: 6, prompt_key: "coverage_prompt", prompt_version: 1,
      prompt_name_snapshot: "Coverage Prompt", latency_ms: 500, input_tokens: 300, output_tokens: 30
    )
    context = admin_context(
      root: Actor.new(id: root),
      filters: { date_range: Window.new(Date.current - 1, Date.current, nil) }
    )
    rows = Widgets.prompt_rows(context)
    used = rows.find { |row| row.key == "coverage_prompt" }
    unused = rows.find { |row| row.key == "unused_prompt" }
    modal = Widgets.prompt_definition_modal(used).to_s
    screen_range = Widgets.registered_prompts_date_range_value(
      admin_context(root: Actor.new(id: root), params: { start_date: "2026-04-01", end_date: "2026-04-02" })
    )

    assert_equal 2, used.calls
    assert_equal 50.0, used.success_rate
    assert_equal 50.0, used.error_rate
    assert_equal "1.0s", used.average_duration
    assert_equal "200", used.average_input_tokens
    assert_equal "20", used.average_output_tokens
    assert_equal(2, used.calls_series.sum { |point| point[:y] })
    assert_equal 0, unused.calls
    assert_equal Copy.t("common.no_data"), unused.average_input_tokens
    assert_equal Copy.t("common.no_data"), Widgets.average_tokens(nil)
    assert_equal "12", Widgets.average_tokens(12.2)
    assert_equal "Coverage Prompt (coverage_prompt v1)", Widgets.prompt_chart_label(used)
    assert_includes Widgets.prompt_calls_path(context, used), "prompt=coverage_prompt"
    assert_includes Widgets.prompt_calls_path(context, used), "prompt_version=1"
    assert_includes Widgets.prompt_calls_path(context, used), "start_date="
    assert_equal Date.new(2026, 4, 1), screen_range.start_date
    assert_equal Date.new(2026, 4, 2), screen_range.end_date
    assert_includes modal, "Coverage Prompt v1"
    assert_includes modal, "coverage_prompt"
    assert_includes modal, "Be brief."
    assert_includes modal, "echo_tool v1"
    assert_includes modal, "write_tool"
    assert_includes modal, Copy.t("common.system_prompt")
    assert_includes modal, Copy.t("common.user_prompt")
    assert_includes modal, "Assistant"
  end

  def test_custom_tool_rows_safety_and_definition
    root = create_recording_id
    echo = register_tool!(key: :echo_tool, name: "Echo", read_only: true, destructive: false,
                          requires_confirmation: false, idempotent: true)
    writer = register_tool!(key: :write_tool, name: "Write", read_only: false, destructive: true,
                            requires_confirmation: true, idempotent: false)
    run = create_run(root_id: root, status: "completed", tokens: 1)
    create_invocation(run, tool_key: "echo_tool", status: "completed", latency_ms: 400)
    create_invocation(run, tool_key: "echo_tool", status: "failed", latency_ms: 600)
    context = admin_context(
      root: Actor.new(id: root),
      filters: { date_range: Window.new(Date.current, Date.current, nil) }
    )
    rows = Widgets.custom_tool_rows(context)
    echo_row = rows.find { |row| row.key == "echo_tool" }
    write_row = rows.find { |row| row.key == "write_tool" }
    modal = Widgets.custom_tool_definition_modal(echo_row).to_s
    screen_range = Widgets.registered_custom_tools_date_range_value(
      admin_context(root: Actor.new(id: root), params: { start_date: "2026-03-01", end_date: "2026-03-08" })
    )

    assert_equal 50.0, echo_row.success_rate
    assert_equal 50.0, echo_row.error_rate
    assert_equal "500ms", echo_row.average_duration
    assert_equal(2, echo_row.calls_series.sum { |point| point[:y] })
    assert_equal(0, write_row.calls_series.sum { |point| point[:y] })
    assert_equal Copy.t("common.read_only_hyphen"), echo_row.safety
    assert_equal(
      Copy.t("common.safety_with_destructive", safety: Copy.t("common.writes")),
      write_row.safety
    )
    assert_includes Widgets.custom_tool_safety_line(echo), Copy.t("common.read_only")
    assert_includes Widgets.custom_tool_safety_line(echo), Copy.t("admin.safety.destructive_no")
    assert_includes Widgets.custom_tool_safety_line(echo), Copy.t("admin.safety.confirmation_not_required")
    assert_includes Widgets.custom_tool_safety_line(writer), Copy.t("common.writes")
    assert_includes Widgets.custom_tool_safety_line(writer), Copy.t("admin.safety.destructive_yes")
    assert_includes Widgets.custom_tool_safety_line(writer), Copy.t("admin.safety.confirmation_required")
    assert_includes Widgets.custom_tool_safety_line(writer), Copy.t("admin.safety.idempotent_no")
    assert_includes modal, "Echo v1"
    assert_includes modal, "When testing Echo"
    assert_equal Date.new(2026, 3, 1), screen_range.start_date
    assert_equal context.filter_value(:date_range), Widgets.registered_custom_tools_date_range_value(context)
  end

  def test_profile_rows_labels_and_filter_values
    @configuration.default_profile = :studio
    @configuration.profiles = {
      empty: [],
      studio: [
        { provider: :openai, model: "gpt-5" },
        RecordingStudioAI::Candidate.new(
          provider: :gemini, model: "gemini-2.5-flash", capabilities: %i[generation decision_choice]
        )
      ],
      plain: [{ provider: :openai, model: "gpt-5-mini", capabilities: [:decision] }]
    }

    rows = Widgets.profile_rows
    empty = rows.find { |row| row.profile == "empty" }
    generated = rows.find { |row| row.profile == "studio" && row.model == "gpt-5" }
    candidate = rows.find { |row| row.model == "gemini-2.5-flash" }
    decision = rows.find { |row| row.model == "gpt-5-mini" }

    assert_equal "—", empty.provider
    assert_nil empty.position
    refute empty.default_profile
    assert generated.default_profile
    assert_equal 1, generated.position
    assert_equal "Generative", generated.kind
    assert_equal "Generative, Decision", candidate.kind
    assert_equal "Decision", decision.kind
    assert_equal Copy.t("common.none"), Widgets.profile_kind_display("—")
    assert_equal Copy.t("common.none"), Widgets.profile_kind_display(nil)
    assert_equal(
      "#{Copy.t('common.generative')}, #{Copy.t('common.decision')}",
      Widgets.profile_kind_display("Generative, Decision")
    )
    assert_equal Copy.t("common.generative"), Widgets.profile_kind_token_label("Generative")
    assert_equal Copy.t("common.decision"), Widgets.profile_kind_token_label("Decision")
    assert_equal "Custom", Widgets.profile_kind_token_label("Custom")
    assert_equal %w[Generative Decision], Widgets.profile_kind_filter_values
    assert_equal %w[empty studio plain], Widgets.profile_name_filter_values
    assert_equal %w[openai gemini], Widgets.profile_provider_filter_values
    assert_includes Widgets.profile_model_filter_values, "gpt-5"
    refute_includes Widgets.profile_model_filter_values, "—"
    assert Widgets.profile_row_has_kind?(candidate, "Decision")
    refute Widgets.profile_row_has_kind?(decision, "Generative")
  end

  def test_latency_rows_paths_and_summary
    root = create_recording_id
    day = Time.zone.parse("2026-05-02 11:00:00")
    previous_day = Time.zone.parse("2026-05-01 11:00:00")
    create_run(
      root_id: root, status: "completed", tokens: 4, created_at: day, latency_ms: 100,
      resolved_model: "gpt-5", prompt_key: "latency_prompt", prompt_version: 2,
      prompt_name_snapshot: "Latency Prompt"
    )
    create_run(
      root_id: root, status: "completed", tokens: 4, created_at: day, latency_ms: 300,
      resolved_model: "gpt-5", prompt_key: "latency_prompt", prompt_version: 2,
      prompt_name_snapshot: "Latency Prompt"
    )
    create_run(
      root_id: root, status: "completed", tokens: 1, created_at: day, latency_ms: 50,
      resolved_model: nil, prompt_key: nil, prompt_name_snapshot: nil
    )
    create_run(
      root_id: root, status: "completed", tokens: 1, created_at: previous_day, latency_ms: 900,
      resolved_model: "gpt-5", prompt_key: "latency_prompt", prompt_version: 2,
      prompt_name_snapshot: "Latency Prompt"
    )
    selected = Window.new(Date.new(2026, 5, 2), Date.new(2026, 5, 2), nil)
    context = admin_context(root: Actor.new(id: root), filters: { date_range: selected })
    model_rows = Widgets.latency_rows(context, dimension: :model)
    prompt_rows = Widgets.latency_rows(context, dimension: :prompt)
    gpt = find_row(model_rows) { |row| row.resolved_model == "gpt-5" }
    unknown = find_row(model_rows) { |row| row.name == Copy.t("common.unknown_model") }
    prompt = find_row(prompt_rows) { |row| row.prompt_key == "latency_prompt" }
    bare = find_row(prompt_rows) { |row| row.name == Copy.t("common.no_prompt") }
    chart_rows = Widgets.latency_chart_rows(
      context, dimension: :model, range: day.beginning_of_day..day.end_of_day, limit: 1
    )
    params_context = admin_context(
      root: Actor.new(id: root), params: { start_date: "2026-05-01", end_date: "2026-05-02" }
    )
    p90_series = Widgets.daily_p90_latency_series(
      RecordingStudioAI::Run.where(root_recording_id: root),
      range: previous_day.beginning_of_day..day.end_of_day
    )

    assert_equal AdminScreens::RecordingStudioAILatencyByModelScreen, Widgets.latency_screen_for(:model)
    assert_equal AdminScreens::RecordingStudioAILatencyByPromptScreen, Widgets.latency_screen_for(:prompt)
    assert_equal 2, gpt.calls
    assert_equal 100, gpt.p50_latency_ms
    assert_equal 300, gpt.p90_latency_ms
    assert_equal 200, gpt.average_latency_ms
    assert_equal 300, gpt.max_latency_ms
    assert_equal 2, series_total(gpt.calls_series)
    assert_equal 1, unknown.calls
    assert_equal 50, unknown.p90_latency_ms
    assert_equal "Latency Prompt v2", prompt.name
    assert_equal 2, prompt.calls
    assert_equal 1, bare.calls
    assert_equal ["gpt-5"], chart_rows.map(&:resolved_model)
    assert_equal chart_rows, Widgets.latency_chart_rows(
      context, dimension: :model, range: day.beginning_of_day..day.end_of_day, limit: 1
    )
    assert_equal 300, Widgets.latency_summary_p90(context, dimension: :model)
    assert_equal 900, Widgets.latency_summary_p90(context, dimension: :model, previous: true)
    assert_equal Date.new(2026, 5, 1), Widgets.latency_date_range_value(params_context, dimension: :prompt).start_date
    assert_equal day.beginning_of_day, Widgets.latency_date_range(context, dimension: :model).begin
    assert_includes Widgets.latency_model_calls_path(context, gpt), "model=gpt-5"
    assert_includes Widgets.latency_model_calls_path(context, gpt), "start_date=2026-05-02"
    assert_includes Widgets.latency_prompt_calls_path(context, prompt), "prompt=latency_prompt"
    assert_includes Widgets.latency_prompt_calls_path(context, prompt), "prompt_version=2"
    assert_equal 900, find_row(p90_series) { |point| point[:x] == "May 1" }.fetch(:y)
    assert_equal 300, find_row(p90_series) { |point| point[:x] == "May 2" }.fetch(:y)
    assert_equal(
      { name: Copy.t("common.unknown_model"), resolved_model: nil },
      Widgets.latency_row_group_key([nil, nil, nil, nil, 50, day], dimension: :model)
    )
    assert_equal(
      { name: "latency_prompt", prompt_key: "latency_prompt", prompt_version: nil },
      Widgets.latency_row_group_key([nil, nil, "latency_prompt", nil, 50, day], dimension: :prompt)
    )
  end

  def test_model_and_provider_rows
    root = create_recording_id
    2.times do
      create_run(
        root_id: root, status: "completed", tokens: 8, resolved_provider: "openai", resolved_model: "gpt-5"
      )
    end
    create_run(
      root_id: root, status: "completed", tokens: 2, resolved_provider: "gemini", resolved_model: "gemini-2.5-flash"
    )
    context = admin_context(root: Actor.new(id: root), filters: { provider: "openai" })
    open_rows = Widgets.model_rows(context)
    definition = RecordingStudioAI.models.fetch(:openai, "gpt-5")
    unsupported = Object.new
    def unsupported.supports_parameter?(_name) = true
    def unsupported.parameter(_name) = { default: nil }
    providers = Widgets.provider_rows(admin_context(root: Actor.new(id: root)))
    openai = providers.find { |row| row.key == "openai" }
    top_models = Widgets.top_model_call_rows(context, range: 1.day.ago..Time.current, limit: 1)
    top_providers = Widgets.top_provider_call_rows(context, range: 1.day.ago..Time.current, limit: 1)

    assert(open_rows.all? { |row| row.provider == "openai" })
    gpt = open_rows.find { |row| row.model == "gpt-5" }
    assert_equal 2, gpt.calls
    assert_equal(2, gpt.calls_series.sum { |point| point[:y] })
    assert_equal "1.0", gpt.temperature
    assert_equal "1.0", Widgets.parameter_default_label(definition, :temperature)
    assert_equal "—", Widgets.parameter_default_label(definition, :not_a_parameter)
    assert_equal "Supported", Widgets.parameter_default_label(unsupported, :temperature)
    assert_equal "/admin/screens/registered_models?provider=openai",
                 Widgets.registered_models_path(context, provider: "openai")
    assert_includes Widgets.registered_provider_keys, "openai"
    assert_equal "OpenAI", openai.class_name
    refute openai.configured
    assert_equal 2, openai.calls
    assert_equal RecordingStudioAI.models.for_provider(:openai).length, openai.models_count
    assert_equal ["openai", "gpt-5", 2], top_models.first.values_at(0, 1, 3)
    assert_equal ["openai", 2], top_providers.first
  end

  def test_retry_rates_and_run_filtered_screen_path
    root = create_recording_id
    retried = create_run(
      root_id: root, status: "completed", tokens: 1, resolved_model: "gpt-5", retry_count: 1
    )
    create_run(root_id: root, status: "failed", tokens: 1, resolved_model: "gpt-5", retry_count: 0)
    create_run(root_id: root, status: "completed", tokens: 1, resolved_model: "gpt-test", retry_count: 0)
    context = admin_context(
      root: Actor.new(id: root),
      filters: { date_range: Window.new(Date.current - 1, Date.current, :custom) }
    )
    rows = Widgets.retry_rate_by_model_rows(RecordingStudioAI::Run.where(root_recording_id: root), limit: 3)
    chart = Widgets.retry_rate_chart_rows(context, range: 2.days.ago..Time.current, limit: 3)
    path = Widgets.run_filtered_screen_path(context, "ai_calls", retried, extra: { status: "failed" })

    assert_equal [["gpt-5", 50.0], ["gpt-test", 0.0]], rows
    assert_equal chart, Widgets.retry_rate_chart_rows(context, range: 2.days.ago..Time.current, limit: 3)
    assert_includes path, "/admin/screens/ai_calls?"
    assert_includes path, "run_id=#{retried.id}"
    assert_includes path, "status=failed"
    assert_includes path, "start_date="
    plain = Widgets.run_filtered_screen_path(context, "attempts")
    refute_includes plain, "run_id="
    assert_includes plain, "/admin/screens/attempts?"
  end

  def test_runs_health_filters_headlines_and_paths
    root = create_recording_id
    other = create_recording_id
    window = Window.new(Date.current - 2, Date.current, nil)
    create_run(
      root_id: root, status: "failed", tokens: 5, profile_key: "fast", error_category: "timeout",
      created_at: Time.current
    )
    create_run(
      root_id: other, status: "failed", tokens: 9, profile_key: "slow", error_category: "timeout",
      created_at: Time.current
    )
    create_run(root_id: root, status: "completed", tokens: 2, profile_key: "fast", created_at: Time.current)
    create_run(
      root_id: root, status: "failed", tokens: 4, profile_key: "fast", error_category: "timeout",
      created_at: (Date.current - 4).in_time_zone.midday
    )
    create_run(
      root_id: root, status: "pending", tokens: 1, profile_key: "fast", created_at: 2.hours.ago
    )
    create_run(root_id: root, status: "pending", tokens: 1, profile_key: "fast", created_at: Time.current)
    context = admin_context(root: Actor.new(id: root), filters: { date_range: window })
    failed_fast = admin_context(
      root: Actor.new(id: root),
      filters: { date_range: window, status: ["failed", ""], profile: ["fast"] }
    )
    stuck = admin_context(root: Actor.new(id: root), filters: { date_range: window, stuck: ["1"] })
    stuck_true = admin_context(root: Actor.new(id: root), filters: { date_range: window, stuck: [true] })
    params_context = admin_context(root: Actor.new(id: root), params: { group_by: "week" })
    no_params = AdminContext.new(
      root: Actor.new(id: root), filters: {}, params: nil, view_context: nil, controller: nil, actor: @actor
    )
    def no_params.respond_to?(method_name, *)
      return false if method_name.to_sym == :params

      super
    end

    assert_equal 5, Health.filtered_runs(context).count
    assert_equal 1, Health.filtered_runs(failed_fast).count
    assert_equal ["failed"], Health.selected_statuses(failed_fast)
    assert_equal ["fast"], Health.selected_profiles(failed_fast)
    assert_equal 1, Health.filtered_runs(stuck).count
    assert Health.stuck?(stuck)
    assert Health.stuck?(stuck_true)
    refute Health.stuck?(context)
    assert_equal :day, Health.group_by_bucket(context)
    assert_equal :week, Health.group_by_bucket(params_context)
    assert_equal window, Health.date_range_window(context)
    assert_equal :last_30_days, Health.date_range_window(no_params).preset_key
    assert Health.created_at_range(context).cover?(Time.current)
    assert Health.created_at_range(context, previous: true).cover?((Date.current - 4).in_time_zone.midday)
    refute Health.created_at_range(context, previous: true).cover?(Time.current)
    assert_equal 2, Health.headline_count(context)
    assert_equal 1, Health.headline_count(context, previous: true)
    assert_equal 1, Health.headline_count(failed_fast)
    assert_equal 1, Health.headline_count(stuck)
    markup = Health.change_markup(context)
    assert_includes markup, "+100%"
    assert_includes markup, Health::DANGER_CLASS
    rows = Health.profile_token_rows(context)
    assert_equal ["fast", 9], [rows.first.profile, rows.first.tokens]
    assert_equal ["slow", 9], [rows.second.profile, rows.second.tokens]
    path = Health.health_screen_path(context, extra: { status: "failed" })
    assert_includes path, "/admin/screens/ai_runs_health?"
    assert_includes path, "date_range_preset=last_30_days"
    assert_includes path, "status=failed"
  end

  def test_runs_health_failed_and_stuck_charts
    root = create_recording_id
    window = Window.new(Date.current - 1, Date.current, nil)
    5.times do
      create_run(
        root_id: root, status: "failed", tokens: 1, error_category: "timeout", created_at: Time.current
      )
    end
    create_run(root_id: root, status: "pending", tokens: 1, created_at: 3.hours.ago)
    failed_context = admin_context(root: Actor.new(id: root), filters: { date_range: window, group_by: :day })
    stuck_context = admin_context(
      root: Actor.new(id: root), filters: { date_range: window, stuck: ["1"], group_by: :day }
    )
    failed = Health.chart_series(failed_context)
    stuck_series = Health.chart_series(stuck_context)
    empty = Health.failed_chart_series(RecordingStudioAI::Run.none, bucket: :day, range: window)
    stamp = Time.zone.parse("2026-05-04 10:00:00")
    counted = Health.bucketed_counts(
      PluckRelation.new([nil, stamp]),
      bucket: :day,
      range: Window.new(Date.new(2026, 5, 4), Date.new(2026, 5, 4), nil)
    )
    skipped = Health.failed_chart_series(
      PluckRelation.new([[nil, nil]] + Array.new(5) { ["timeout", stamp] }),
      bucket: :day,
      range: Window.new(Date.new(2026, 5, 4), Date.new(2026, 5, 4), nil)
    )

    assert_equal "timeout", failed.first[:name]
    assert_equal(5, failed.first[:data].sum { |point| point[:y] })
    assert_equal Copy.t("admin.widgets.stuck.title"), stuck_series.first[:name]
    assert_equal(1, stuck_series.first[:data].sum { |point| point[:y] })
    assert_equal Copy.t("admin.screens.ai_runs_health.chart_title"), empty.first[:name]
    assert(empty.first[:data].all? { |point| point[:y].zero? })
    assert_equal "timeout", Health.failed_series_name("timeout")
    assert_equal(1, counted.sum { |point| point[:y] })
    assert_equal(5, skipped.first[:data].sum { |point| point[:y] })
  end

  def test_metric_read_returns_numeric_series_for_site_runs
    root = create_recording_id
    today = Time.current
    yesterday = 1.day.ago
    create_run(root_id: root, status: "completed", tokens: 5, profile_key: "fast", created_at: today)
    create_run(
      root_id: root, status: "failed", tokens: 7, profile_key: "fast", error_category: "timeout",
      created_at: today
    )
    create_run(root_id: root, status: "completed", tokens: 3, profile_key: nil, created_at: yesterday)
    4.times do
      create_run(
        root_id: root, status: "failed", tokens: 0, profile_key: "fast", error_category: "timeout",
        created_at: today
      )
    end
    context = admin_context(
      root: Actor.new(id: root),
      filters: { date_range: Window.new(Date.current - 1, Date.current, nil) }
    )
    RecordingStudioMetrics::Adapters.stub(:for_connection, SqliteDayAdapter) do
      total = MetricsRead.scalar("ai_runs.tokens", admin_context: context, cache: false)
      profiles = MetricsRead.profile_token_rows(context)
      breakdown = MetricsRead.chart_series("ai_runs.by_status", admin_context: context, kind: :breakdown, cache: false)
      ranged = MetricsRead.chart_series("ai_runs.over_time", admin_context: context, kind: :timeseries, cache: false)
      sliced = MetricsRead.chart_series(
        "ai_runs.over_time",
        admin_context: admin_context(root: Actor.new(id: root)),
        kind: :timeseries,
        cache: false,
        start_at: Date.current.beginning_of_day,
        end_at: Date.current.next_day.beginning_of_day
      )
      grouped = MetricsRead.chart_series(
        "ai_runs.failed_over_time",
        admin_context: context,
        kind: :timeseries_groups,
        group_by: :error_category,
        cache: false
      )

      labeled = profiles.to_h { |row| [row.profile, row.tokens] }
      assert_equal 15, total
      assert_equal 12, labeled["fast"]
      assert_equal 3, labeled[Copy.t("common.none")]
      assert_equal [2.0, 5.0], breakdown.first[:data].sort
      assert_equal "AI runs over time", ranged.first[:name]
      assert_equal 2, ranged.first[:data].length
      assert_equal(7.0, ranged.first[:data].sum { |point| point[:y] })
      assert_equal(6.0, sliced.first[:data].sum { |point| point[:y] })
      assert_equal 1, sliced.first[:data].length
      timeout = grouped.find { |series| series[:name] == "timeout" }
      assert_equal(5.0, timeout[:data].sum { |point| point[:y] })
    end

    empty_groups = RecordingStudioMetrics::Result.new(
      metric: "ai_runs.failed_over_time",
      type: :timeseries,
      title: "Failed AI runs",
      data: [{ date: "2026-05-04", value: 4 }],
      groups: [{ key: "timeout", data: [] }]
    )
    fallback = MetricsRead.series_from_result(empty_groups, kind: :timeseries_groups)
    assert_equal [{ x: "2026-05-04", y: 4.0 }], fallback.first[:data]
    assert_equal "Failed AI runs", fallback.first[:name]
    assert_equal "fast", MetricsRead.profile_label("fast")
    assert_equal Copy.t("common.none"), MetricsRead.profile_label(nil)
  end

  private

  def admin_context(root: nil, filters: {}, params: {}, view_context: nil, controller: nil)
    AdminContext.new(
      root: root || Actor.new(id: create_recording_id),
      filters: filters,
      params: params,
      view_context: view_context,
      controller: controller,
      actor: @actor
    )
  end

  def create_run(root_id:, status:, tokens:, **attributes)
    RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      root_recording_id: root_id,
      initiator_type: "User",
      initiator_id: @actor.id,
      initiator_kind: "user",
      total_tokens: tokens,
      created_at: Time.current,
      **attributes
    )
  end

  def create_attempt(run, kind:, **attributes)
    values = {
      status: "completed",
      created_at: Time.current,
      provider: "openai",
      model: "gpt-5"
    }.merge(attributes)
    run.attempts.create!(
      sequence: run.attempts.count + 1,
      kind: kind,
      status: values[:status],
      provider: values[:provider],
      model: values[:model],
      error_code: values[:error_code],
      created_at: values[:created_at]
    )
  end

  def create_invocation(run, tool_key:, status:, latency_ms: 100, tool_version: 1)
    run.custom_tool_invocations.create!(
      tool_key: tool_key,
      tool_version: tool_version,
      status: status,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      latency_ms: latency_ms,
      created_at: run.created_at
    )
  end

  def register_tool!(key:, name:, **safety)
    flags = {
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true
    }.merge(safety)
    RecordingStudioAI.tools.register(
      key: key,
      version: 1,
      name: name,
      description: "#{name} description",
      use_when: "When testing #{name}",
      do_not_use_when: "Outside tests",
      parameters: [],
      returns: "A result",
      cost: :low,
      latency: :fast,
      read_only: flags[:read_only],
      destructive: flags[:destructive],
      requires_confirmation: flags[:requires_confirmation],
      idempotent: flags[:idempotent],
      executor_label: "Tests.#{key}",
      executor: ->(_arguments, _context) { { ok: true } }
    )
  end

  def register_prompt!(tools:)
    RecordingStudioAI.prompts.register(
      owner: "Host",
      key: :coverage_prompt,
      version: 1,
      name: "Coverage Prompt",
      description: "Prompt used by coverage tests.",
      inputs: [:customer_name],
      messages: [
        { role: :system, content: "Be brief." },
        { role: :user, content: "Hello {{customer_name}}" },
        { role: :assistant, content: "Ready." }
      ],
      tools: tools,
      defaults: { profile: "medium" }
    )
  end

  def isolate_prompt_registry!
    @original_prompts = RecordingStudioAI.instance_variable_get(:@prompts)
    RecordingStudioAI.instance_variable_set(:@prompts, RecordingStudioAI::Prompts::Registry.new)
  end

  def restore_prompt_registry!
    return unless instance_variable_defined?(:@original_prompts)

    RecordingStudioAI.instance_variable_set(:@prompts, @original_prompts)
  end

  def install_flatpack_fakes!
    return if defined?(FlatPack::Chart::Component)

    @installed_flatpack_module = !defined?(FlatPack)
    Object.const_set(:FlatPack, Module.new) if @installed_flatpack_module
    install_flatpack_component(:Link, :LinkComponent)
    install_flatpack_component(:Card, :CardComponent)
    install_flatpack_component(:Modal, :ModalComponent)
    install_flatpack_component(:Chart, :ChartComponent)
    install_flatpack_component(:CodeBlock, :CodeBlockComponent)
    @flatpack_fakes_installed = true
  end

  def install_flatpack_component(namespace_name, component_name)
    namespace = FlatPack.const_set(namespace_name, Module.new)
    namespace.const_set(:Component, AdminWidgetCoverageFlatPack.const_get(component_name))
  end

  def remove_flatpack_fakes!
    return unless @flatpack_fakes_installed

    %i[Link Card Modal Chart CodeBlock].each do |name|
      FlatPack.send(:remove_const, name) if FlatPack.const_defined?(name, false)
    end
    Object.send(:remove_const, :FlatPack) if @installed_flatpack_module
    @flatpack_fakes_installed = false
  end

  def hide_admin_period!
    return unless defined?(RecordingStudioAdmin::Period)

    RecordingStudioAdmin.send(:remove_const, :Period)
  end

  def restore_admin_period!(period)
    return unless period

    admin = defined?(RecordingStudioAdmin) ? RecordingStudioAdmin : Object.const_set(:RecordingStudioAdmin, Module.new)
    admin.const_set(:Period, period) unless admin.const_defined?(:Period, false)
  end

  def with_admin_period
    if defined?(RecordingStudioAdmin::Period)
      yield
      return
    end

    admin = defined?(RecordingStudioAdmin) ? RecordingStudioAdmin : Object.const_set(:RecordingStudioAdmin, Module.new)
    admin.const_set(:Period, AdminWidgetCoveragePeriod)
    @installed_admin_period = true
    yield
  ensure
    if @installed_admin_period
      RecordingStudioAdmin.send(:remove_const, :Period) if RecordingStudioAdmin.const_defined?(:Period, false)
      @installed_admin_period = false
    end
  end

  def find_row(rows, &)
    rows.find(&)
  end

  def series_total(points)
    points.sum { |point| point[:y] }
  end

  def warning_icons(warnings)
    warnings.map { |warning| warning[:icon] }
  end
end
