# frozen_string_literal: true

require "test_helper"

class LibraryGapCoverageTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class CapturingProvider < RecordingStudioAI::Providers::Base
    attr_reader :requests

    def initialize
      super
      @requests = []
    end

    def generate(request:, candidate:)
      requests << { operation: :generate, request: request, candidate: candidate }
      RecordingStudioAI::Providers::Result.new(text: "ok", finish_reason: "stop")
    end

    def stream(request:, candidate:)
      requests << { operation: :stream, request: request, candidate: candidate }
      yield RecordingStudioAI::Providers::StreamEvent.new(type: :text_delta, text_delta: "ok")
      RecordingStudioAI::Providers::Result.new(text: "ok", finish_reason: "stop")
    end
  end

  class GapHostedAdapter < RecordingStudioAI::Providers::Base
    provider_key :openai

    attr_reader :creates, :streams, :recoveries
    attr_accessor :create_failure, :recovery_error, :recovery_failure_at, :events

    def initialize
      super
      @creates = []
      @streams = []
      @recoveries = []
      @events = []
    end

    def create_hosted_agent_session(instructions:, model:, input:, idempotency_key:, tools: nil)
      creates << {
        instructions: instructions, model: model, input: input, idempotency_key: idempotency_key, tools: tools
      }
      raise create_failure if create_failure

      hosted_session(model)
    end

    def stream_hosted_agent_session(provider_session_id:, &)
      streams << provider_session_id
      Array(events).each(&)
    end

    def recover_hosted_agent_session(provider_session_id:, provider_turn_id: nil)
      recoveries << { provider_session_id: provider_session_id, provider_turn_id: provider_turn_id }
      raise recovery_error if recovery_failure_at && recoveries.length >= recovery_failure_at

      hosted_recovery(provider_session_id)
    end

    private

    def hosted_session(model)
      RecordingStudioAI::Providers::HostedSession.new(
        provider_session_id: "sess_gap", status: "in_progress", model: model
      )
    end

    def hosted_recovery(provider_session_id)
      RecordingStudioAI::Providers::HostedRecovery.new(
        session: hosted_session("gpt-6-astra").with(provider_session_id: provider_session_id),
        turn: RecordingStudioAI::Providers::HostedTurn.new(
          provider_turn_id: "turn_gap", status: "in_progress", usage: nil, error: nil
        ),
        items: [],
        tool_calls: []
      )
    end
  end

  class SignatureApi
    attr_accessor :outcome

    def initialize
      @outcome = false
    end

    def verify_signature(_payload, _headers, _secret)
      raise outcome if outcome.is_a?(Exception)

      outcome
    end
  end

  class SignatureClient
    def initialize(api)
      @api = api
    end

    def webhooks
      @api
    end
  end

  def setup
    super
    @root = Actor.new(create_recording_id)
    @initiator = Actor.new(51)
    isolate_allow_all_configuration!
    isolate_tools_registry!
    isolate_prompt_registry!
  end

  def teardown
    restore_prompt_registry!
    super
  end

  def test_metrics_register_is_a_no_op_when_already_registered
    RecordingStudioAI::Metrics.register!
    run_ids = RecordingStudioMetrics.for_resource(:ai_runs).map(&:object_id)
    batch_ids = RecordingStudioMetrics.for_resource(:ai_batches).map(&:object_id)
    assert_predicate run_ids, :any?
    assert_predicate batch_ids, :any?

    RecordingStudioAI::Metrics.register!
    assert_equal run_ids, RecordingStudioMetrics.for_resource(:ai_runs).map(&:object_id)
    assert_equal batch_ids, RecordingStudioMetrics.for_resource(:ai_batches).map(&:object_id)
  end

  def test_stuck_metric_filters_come_from_list_filters_with_status
    RecordingStudioAI::Metrics.register!
    with_status = RecordingStudioAI::Metrics.list_filters(status: true).map(&:name)
    without_status = RecordingStudioAI::Metrics.list_filters.map(&:name)
    stuck = RecordingStudioMetrics.find("ai_runs.stuck")
    oldest = RecordingStudioMetrics.find("ai_runs.oldest_stuck_age")
    failed = RecordingStudioMetrics.find("ai_runs.failed_over_time")
    status_filter = stuck.filters.find { |filter| filter.name == :status }

    assert_includes with_status, :status
    refute_includes without_status, :status
    assert_equal with_status, stuck.filters.map(&:name)
    assert_equal with_status, oldest.filters.map(&:name)
    assert_equal without_status, failed.filters.map(&:name)
    assert_equal %w[pending running], status_filter.options
  end

  def test_failed_and_stuck_scopes_count_sqlite_runs
    RecordingStudioAI::Metrics.register!
    failed = create_metric_run(status: "failed", error_category: "provider_error")
    pending = create_metric_run(status: "pending", created_at: 2.hours.ago)
    fresh = create_metric_run(status: "running", started_at: Time.current)
    relation = RecordingStudioAI::Run.all
    failed_ids = RecordingStudioMetrics.find("ai_runs.failed_over_time").scope.call(relation).pluck(:id)
    stuck_ids = RecordingStudioMetrics.find("ai_runs.stuck").scope.call(relation).pluck(:id)

    assert_equal [failed.id], failed_ids
    assert_equal [pending.id], stuck_ids
    refute_includes stuck_ids, fresh.id
    assert_equal "running", fresh.reload.status
    assert_equal 1, execute_metric("ai_runs.stuck").value
    assert_equal 1, execute_metric("ai_runs.stuck", filters: { status: "pending" }).value
    assert_equal 0, execute_metric("ai_runs.stuck", filters: { status: "running" }).value
  end

  def test_oldest_stuck_age_and_stuck_over_time_read_sqlite_runs
    RecordingStudioAI::Metrics.register!
    create_metric_run(status: "pending", created_at: 2.hours.ago)
    create_metric_run(status: "running", started_at: Time.current)
    create_metric_run(status: "failed", error_category: "provider_error")
    oldest = execute_metric("ai_runs.oldest_stuck_age")
    over_time = execute_metric("ai_runs.stuck_over_time")
    total = over_time.data.sum { |row| row[:value] || row["value"] }

    assert_equal "seconds", oldest.unit
    assert_operator oldest.value, :>=, RecordingStudioAI.configuration.stuck_run_threshold.to_i
    assert_equal 30, over_time.data.length
    assert_operator total, :>=, 1
  end

  def test_admin_root_recording_is_nil_without_the_admin_constant
    without_constant(:RecordingStudioAdmin) do
      assert_nil RecordingStudioAI::Api::Access.admin_root_recording
      refute RecordingStudioAI::Api::Access.can_view?(nil)
      refute RecordingStudioAI::Api::Access.can_view?(access_context(nil))
      refute RecordingStudioAI::Api::Access.authorized_on_admin_root?(access_context(Object.new), :view)
    end
  end

  def test_admin_root_recording_resolver_nil_raise_and_value
    recording = Object.new
    with_admin_configuration do |config|
      config.site_admin_recording_resolver = nil
      config.access_recording_resolver = nil
      assert_nil RecordingStudioAI::Api::Access.admin_root_recording

      config.access_recording_resolver = ->(_context) { recording }
      assert_same recording, RecordingStudioAI::Api::Access.admin_root_recording

      config.site_admin_recording_resolver = ->(_context) { raise StandardError, "resolver failed" }
      assert_nil RecordingStudioAI::Api::Access.admin_root_recording

      config.site_admin_recording_resolver = lambda { |context|
        recording if context.is_a?(RecordingStudioAI::Api::Access::ResolverContext) && context.controller.nil?
      }
      assert_same recording, RecordingStudioAI::Api::Access.admin_root_recording
    end
  end

  def test_can_view_is_false_without_an_actor_or_accessible
    recording = Object.new
    actor = Object.new
    with_admin_configuration do |config|
      config.site_admin_recording_resolver = ->(_context) { recording }
      refute RecordingStudioAI::Api::Access.can_view?(access_context(nil))
      refute RecordingStudioAI::Api::Access.authorized_on_admin_root?(access_context(nil), :view)

      without_constant(:RecordingStudioAccessible) do
        refute RecordingStudioAI::Api::Access.can_view?(access_context(actor))
        install_accessible_double
        assert RecordingStudioAI::Api::Access.can_view?(access_context(actor))
        refute RecordingStudioAI::Api::Access.authorized_on_admin_root?(access_context(actor), :edit)
        remove_accessible_double
      end
    end
  end

  def test_discover_providers_registers_each_missing_subclass_once
    probe = Class.new(RecordingStudioAI::Providers::Base) { provider_key :gap_coverage_probe }
    RecordingStudioAI::Providers.const_set(:GapCoverageProbe, probe)
    keys = RecordingStudioAI.discover_providers!
    provider = RecordingStudioAI.configuration.providers.fetch(:gap_coverage_probe)

    assert_includes keys, :gap_coverage_probe
    assert_equal keys, keys.uniq
    assert_kind_of RecordingStudioAI::Providers::Base, provider
    assert_equal :gap_coverage_probe, provider.class.provider_key
    keys.each do |key|
      assert_kind_of RecordingStudioAI::Providers::Base, RecordingStudioAI.configuration.providers.fetch(key)
    end

    again = RecordingStudioAI.discover_providers!
    refute_includes again, :gap_coverage_probe
    assert_empty(again & keys)
    assert_same provider, RecordingStudioAI.configuration.providers.fetch(:gap_coverage_probe)
  ensure
    if RecordingStudioAI::Providers.const_defined?(:GapCoverageProbe, false)
      RecordingStudioAI::Providers.send(:remove_const, :GapCoverageProbe)
    end
  end

  def test_unknown_prompt_and_missing_prompt_method
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.prompt(:missing_gap_prompt)
    end
    proxy = RecordingStudioAI.prompt_methods
    missing = assert_raises(NoMethodError) { proxy.missing_gap_prompt(inputs: {}) }

    assert_equal "invalid_request", error.code
    assert_includes error.message, "missing_gap_prompt is not registered"
    assert_instance_of RecordingStudioAI::Prompts::MethodProxy, proxy
    assert_same proxy, RecordingStudioAI.prompt_methods
    assert_includes missing.message, "missing_gap_prompt"
  end

  def test_prompt_registration_rejects_invalid_normalizers
    cases = [
      [{ owner: "bad owner" }, "prompt owner must be a gem or host label"],
      [{ owner: " " }, "prompt owner must be a non-empty label"],
      [{ overridable: "yes" }, "prompt overridable must be true or false"],
      [{ inputs: [:Customer] }, "prompt inputs must be an Array of snake_case names"],
      [{ inputs: %i[customer_name customer_name] }, "prompt inputs must be unique"],
      [{ messages: [] }, "prompt messages must be a non-empty Array"],
      [{ messages: [{ role: "user" }] }, "prompt messages[0] must include a valid role and non-empty content"],
      [{ tools: "listed_tool" }, "prompt tools must be an Array"],
      [{ tools: [{ key: "Bad" }] }, "prompt tools[0] must identify a registered tool"]
    ]
    cases.each do |overrides, fragment|
      assert_prompt_rejected(fragment) { RecordingStudioAI.prompts.register(**prompt_attributes(overrides)) }
    end
    assert_empty RecordingStudioAI.prompts.all
  end

  def test_prompt_call_bang_raises_when_no_provider_is_configured
    invocation = register_invocation
    error = assert_raises(RecordingStudioAI::Errors::ExecutionError) do
      invocation.call!(inputs: prompt_inputs, **attribution)
    end

    assert_equal "not_implemented", error.response.error.code
    assert_equal "configuration", error.response.error.category
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_prompt_call_bang_merges_caller_tools_into_the_provider_request
    register_gap_tool(:listed_tool)
    register_gap_tool(:extra_tool)
    invocation = register_invocation(tools: [{ key: :listed_tool, version: 1 }])
    provider = install_capturing_provider
    response = invocation.call!(
      inputs: prompt_inputs,
      custom_tools: [{ key: :extra_tool, version: 1 }],
      **attribution
    )

    assert_predicate response, :success?
    assert_equal "ok", response.text
    assert_equal "generation", response.operation
    assert_equal %w[listed_tool extra_tool], tool_keys(provider, :generate)
    assert_equal "completed", RecordingStudioAI::Run.sole.status
  end

  def test_prompt_stream_and_stream_bang
    register_gap_tool(:listed_tool)
    register_gap_tool(:extra_tool)
    invocation = register_invocation(tools: [{ key: :listed_tool, version: 1 }])
    provider = install_capturing_provider
    blocked = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      invocation.stream!(inputs: prompt_inputs, **attribution)
    end
    assert_equal "invalid_request", blocked.code
    assert_includes blocked.message, "requires a block"
    assert_empty provider.requests

    events = []
    streamed = invocation.stream(inputs: prompt_inputs, **attribution) { |event| events << event }
    streamed_bang = invocation.stream!(
      inputs: prompt_inputs,
      custom_tools: [{ key: :extra_tool, version: 1 }],
      **attribution
    ) { |_event| }

    assert_predicate streamed, :success?
    assert_equal "ok", streamed.text
    assert_equal "stream", streamed.operation
    assert_includes events.map(&:type), "text_delta"
    assert_includes events.map(&:type), "completed"
    assert_predicate streamed_bang, :success?
    assert_equal "ok", streamed_bang.text
    assert_equal([%w[listed_tool], %w[listed_tool extra_tool]], provider.requests.map do |call|
      call.fetch(:request).fetch(:custom_tools).map { |tool| tool.fetch(:key) }
    end)
  end

  def test_prompt_invocation_rejects_bad_tool_references
    register_gap_tool(:listed_tool)
    invocation = register_invocation(tools: [{ key: :listed_tool, version: 1 }])
    provider = install_capturing_provider
    assert_invocation_invalid("custom_tools must be an Array") do
      invocation.call!(inputs: prompt_inputs, custom_tools: "nope", **attribution)
    end
    assert_invocation_invalid("custom_tools[0] must be a Hash") do
      invocation.call!(inputs: prompt_inputs, custom_tools: ["nope"], **attribution)
    end
    assert_invocation_invalid("registered prompt tool missing_tool is not registered") do
      invocation.call!(inputs: prompt_inputs, custom_tools: [{ key: :missing_tool, version: 1 }], **attribution)
    end
    assert_empty provider.requests
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_validate_rejects_invalid_bounds_and_timeouts
    assert_configuration_invalid("maximum_decision_characters must be at least maximum_decision_text_characters") do |c|
      c.maximum_decision_state_characters = 10
      c.maximum_decision_text_characters = 50
      c.maximum_decision_characters = 20
    end
    assert_configuration_invalid("maximum_attachment_count must be an Integer greater than or equal to 0") do |c|
      c.maximum_attachment_count = -1
    end
    assert_configuration_invalid("request_timeout must be a finite number greater than or equal to 0") do |c|
      c.request_timeout = -1
    end
    assert_configuration_invalid("retry_jitter must be a finite number between 0 and 1") { |c| c.retry_jitter = 1.5 }
    assert_configuration_invalid("custom_tool_timeout must be a finite number greater than or equal to 0") do |c|
      c.custom_tool_timeout = Float::INFINITY
    end
    assert_configuration_invalid("retry_backoff_max must be greater than or equal to retry_backoff_base") do |c|
      c.retry_backoff_base = 2
      c.retry_backoff_max = 1
    end
  end

  def test_validate_rejects_invalid_callbacks_and_durations
    assert_configuration_invalid("retry_random must respond to call") { |c| c.retry_random = "nope" }
    assert_configuration_invalid("retry_sleeper must respond to call") { |c| c.retry_sleeper = "nope" }
    assert_configuration_invalid("execution_history_retention_period must be nil or a positive duration") do |c|
      c.execution_history_retention_period = 0
    end
    assert_configuration_invalid("execution_history_retention_period must be nil or a positive duration") do |c|
      c.execution_history_retention_period = Object.new
    end
    assert_configuration_invalid("batch_synchronization_interval must be a positive duration") do |c|
      c.batch_synchronization_interval = 0
    end
    assert_configuration_invalid("response_retention_period must be a positive duration") do |c|
      c.response_retention_period = "week"
    end
    assert_configuration_invalid("batch_synchronization_job must respond to perform_later") do |c|
      c.batch_synchronization_job = Object.new
    end
    assert_configuration_invalid("webhook_batch_initiator must be nil or respond to call") do |c|
      c.webhook_batch_initiator = "nope"
    end
  end

  def test_validate_rejects_invalid_model_fallback_keys_and_accepts_a_map
    entry = [{ provider: :gemini, model: "gemini-2.5-flash" }]
    assert_configuration_invalid("model_fallbacks must be a Hash") { |c| c.model_fallbacks = [] }
    assert_configuration_invalid("model_fallbacks keys must be [provider, model] or") do |c|
      c.model_fallbacks = { openai: entry }
    end
    assert_configuration_invalid("model_fallbacks keys must be [provider, model]") do |c|
      c.model_fallbacks = { [:openai] => entry }
    end
    assert_configuration_invalid("model_fallbacks string keys must look like provider/model") do |c|
      c.model_fallbacks = { "openai" => entry }
    end
    assert_configuration_invalid("model_fallbacks provider is required") do |c|
      c.model_fallbacks = { ["", "gpt-5"] => entry }
    end
    assert_configuration_invalid("model_fallbacks model is required") do |c|
      c.model_fallbacks = { [:openai, " "] => entry }
    end
    assert_configuration_invalid("model_fallbacks[openai/gpt-5] must be a non-empty Array") do |c|
      c.model_fallbacks = { [:openai, "gpt-5"] => [] }
    end

    configuration = RecordingStudioAI::Configuration.new
    configuration.profiles = { medium: [{ provider: :openai, model: "gpt-5" }] }
    configuration.model_fallbacks = {
      [:openai, "gpt-5"] => [{ provider: :gemini, model: "gemini-2.5-pro" }],
      "openai/gpt-5-mini" => [{ provider: :openai, model: "gpt-5" }]
    }
    configuration.execution_history_retention_period = 1.day
    configuration.retry_jitter = 1
    configuration.request_timeout = 0
    configuration.webhook_batch_initiator = ->(**) {}
    job = Object.new
    job.define_singleton_method(:perform_later) { |*| :enqueued }
    configuration.batch_synchronization_job = job

    assert_same configuration, configuration.validate!
    assert_equal [{ provider: :gemini, model: "gemini-2.5-pro" }], configuration.model_fallbacks_for(:openai, "gpt-5")
    assert_equal [{ provider: :openai, model: "gpt-5" }], configuration.model_fallbacks_for(:openai, "gpt-5-mini")
  end

  def test_validate_rejects_invalid_credit_billing
    assert_configuration_invalid("usage_precheck must respond to call") { |c| c.usage_precheck = "nope" }
    assert_configuration_invalid("minimum_credit_balance must be an Integer greater than or equal to 1") do |c|
      c.minimum_credit_balance = 0
    end
    assert_configuration_invalid("credit_prices must be a Hash") do |c|
      c.usage_handler = ->(**) {}
      c.usage_precheck = ->(**) { true }
      c.credit_prices = []
    end
    assert_configuration_invalid("credit_prices[*] input must be a whole number of credits") do |c|
      c.usage_handler = ->(**) {}
      c.usage_precheck = ->(**) { true }
      c.credit_prices = { "*" => { input: -1 } }
    end
  end

  def test_recording_attribution_mismatches_and_lookup
    configuration = RecordingStudioAI::Configuration.new
    plain = Object.new
    assert_same plain, configuration.resolved_root_recording(plain)

    with_recording_double do |recording_class|
      root_id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      child_id = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      other_id = "cccccccc-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      missing_id = "dddddddd-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      root = recording_class.new(id: root_id, parent_recording_id: nil, root_recording_id: root_id)
      child = recording_class.new(id: child_id, parent_recording_id: root_id, root_recording_id: root_id)
      stranger = recording_class.new(id: other_id, parent_recording_id: root_id, root_recording_id: other_id)
      recording_class.remember(root)
      assert_nil configuration.resolved_root_recording(missing_id)
      carrier = Struct.new(:root_recording_id).new(missing_id)
      assert_nil configuration.resolved_root_recording(carrier)
      assert_same root, configuration.resolved_root_recording(root_id)
      assert_same root, configuration.resolved_root_recording(root)
      assert_nil configuration.attribution_validator.call(root_recording: root_id, context_recording: nil)
      assert_nil configuration.attribution_validator.call(root_recording: root, context_recording: child)

      mismatch = assert_raises(ArgumentError) do
        configuration.attribution_validator.call(root_recording: root, context_recording: stranger)
      end
      foreign = assert_raises(ArgumentError) do
        configuration.attribution_validator.call(root_recording: root, context_recording: Object.new)
      end
      not_root = assert_raises(ArgumentError) do
        configuration.attribution_validator.call(root_recording: child, context_recording: nil)
      end
      assert_equal "context_recording must belong to root_recording", mismatch.message
      assert_equal "context_recording must belong to root_recording", foreign.message
      assert_equal "root_recording must be a Recording Studio root", not_root.message
    end
    refute RecordingStudio.const_defined?(:Recording, false)
  end

  def test_tool_parameter_schemas_are_rejected
    cases = [
      [nil, "tool parameters must be an Array"],
      [["count"], "tool parameters[0] must be a Hash"],
      [[{ name: :count, type: :integer, required: true, description: "How many.", extra: true }], "unknown keys"],
      [[{ name: "Count", type: :integer, required: true, description: "How many." }],
       "tool parameter name must be snake_case"],
      [[{ name: :count, type: :date, required: true, description: "How many." }],
       "tool parameter type must be one of:"],
      [[{ name: :count, type: :integer, required: "yes", description: "How many." }],
       "tool parameter required must be true or false"],
      [[{ name: :count, type: :integer, required: true, description: " " }],
       "tool parameter description must be a non-empty String"],
      [[{ name: :count, type: :integer, required: true, description: "How many.", allowed_values: [] }],
       "tool parameter allowed_values must be a non-empty Array"],
      [[{ name: :count, type: :integer, required: true, description: "How many.", default: "nope" }],
       "custom tool argument count must be a integer"],
      [[
        { name: :count, type: :integer, required: true, description: "How many." },
        { name: :count, type: :string, required: false, description: "Again." }
      ], "tool parameter names must be unique"]
    ]
    cases.each do |parameters, fragment|
      assert_tool_rejected(fragment) { register_counted_tool(parameters: parameters) }
    end
    assert_nil RecordingStudioAI.tools.fetch(:gap_tool)
  end

  def test_validate_arguments_rejects_type_and_missing_required
    definition = register_counted_tool(parameters: [
                                         { name: :count, type: :integer, required: true, description: "How many." },
                                         { name: :label, type: :string, required: false,
                                           description: "Optional label.", default: "note" }
                                       ])
    wrong_type = argument_error { definition.validate_arguments!("count" => "12") }
    missing = argument_error { definition.validate_arguments!({}) }
    wrapped = argument_error { definition.validate_arguments!("count" => Object.new) }

    assert_equal "custom_tool_validation", wrong_type.code
    assert_equal "custom tool argument count must be a integer", wrong_type.message
    assert_equal "custom_tool_validation", missing.code
    assert_equal "missing required custom tool argument: count", missing.message
    assert_equal "custom_tool_validation", wrapped.code
    assert_includes wrapped.message, "primitive JSON-like values"
    assert_equal({ "count" => 3, "label" => "note" }, definition.validate_arguments!("count" => 3))
  end

  def test_hosted_agent_precheck_refusal_fails_the_run_without_calling_the_provider
    adapter = install_hosted_adapter
    RecordingStudioAI.configuration.usage_handler = ->(**) { flunk "handler must not run" }
    RecordingStudioAI.configuration.credit_prices = { "*" => { input: 1 } }
    RecordingStudioAI.configuration.usage_precheck = ->(**) { raise "credits exhausted" }
    error = assert_raises(RuntimeError) { create_hosted_session }
    run = RecordingStudioAI::Run.sole

    assert_equal "credits exhausted", error.message
    assert_empty adapter.creates
    assert_equal "failed", run.status
    assert_equal RecordingStudioAI::Usage::DECLINED_CATEGORY, run.error_category
    assert_equal RecordingStudioAI::Usage::DECLINED_CODE, run.error_code
    assert_equal "credits exhausted", run.error_message
  end

  def test_hosted_agent_recovery_timeout_leaves_the_run_running
    adapter = install_hosted_adapter
    adapter.recovery_failure_at = 2
    adapter.recovery_error = hosted_failure("timeout", "timeout", "Provider request timed out.")
    session = create_hosted_session
    error = assert_raises(RecordingStudioAI::Agents::Failure) do
      RecordingStudioAI::Agents.stream(session: session, **attribution) { |_event| }
    end
    run = RecordingStudioAI::Run.find(session.run_id)

    assert_equal "timeout", error.error.category
    assert_equal "running", run.status
    assert_nil run.error_category
    assert_equal 1, adapter.creates.length
    assert_equal 1, adapter.streams.length
    assert_equal 2, adapter.recoveries.length
  end

  def test_hosted_agent_provider_failure_fails_the_run
    adapter = install_hosted_adapter
    adapter.create_failure = hosted_failure("provider_error", "provider_error", "Provider failed.")
    error = assert_raises(RecordingStudioAI::Agents::Failure) { create_hosted_session }
    run = RecordingStudioAI::Run.sole

    assert_equal "provider_error", error.error.category
    assert_equal "failed", run.status
    assert_equal "provider_error", run.error_category
    assert_equal "provider_error", run.error_code
    assert_equal 1, adapter.creates.length
    assert_empty adapter.streams
  end

  def test_openai_webhook_verifiers_extractors_and_missing_gem
    api = SignatureApi.new
    configuration = RecordingStudioAI.configuration
    configuration.openai_client = SignatureClient.new(api)
    configuration.openai_webhook_secret = nil
    verifier = RecordingStudioAI::Webhooks::OpenaiProvider.signature_verifier
    context = Struct.new(:raw_payload, :headers).new("{}", {})
    refute verifier.call(context)

    configuration.openai_webhook_secret = ""
    refute verifier.call(context)

    configuration.openai_webhook_secret = "whsec"
    api.outcome = false
    refute verifier.call(context)
    api.outcome = nil
    assert verifier.call(context)
    api.outcome = RuntimeError.new("boom")
    refute verifier.call(context)
    assert_same configuration.openai_client, RecordingStudioAI::Webhooks::OpenaiProvider.openai_client("whsec")

    payload = { "id" => "evt_1", "type" => "batch.completed", "data" => { "id" => "batch_1" } }
    assert_equal "batch.completed", RecordingStudioAI::Webhooks::OpenaiProvider.event_type_extractor.call(payload)
    assert_equal "evt_1", RecordingStudioAI::Webhooks::OpenaiProvider.event_id_extractor.call(payload)
    assert_nil RecordingStudioAI::Webhooks::OpenaiProvider.event_type_extractor.call("nope")
    assert_nil RecordingStudioAI::Webhooks::OpenaiProvider.event_id_extractor.call(nil)

    error = assert_raises(LoadError) { RecordingStudioAI::Webhooks::OpenaiProvider.register! }
    assert_equal(
      "recording_studio_webhooks is required to register the OpenAI webhook provider",
      error.message
    )
  end

  private

  def isolate_prompt_registry!
    @original_prompts = RecordingStudioAI.instance_variable_get(:@prompts)
    @original_prompt_methods = RecordingStudioAI.instance_variable_get(:@prompt_methods)
    RecordingStudioAI.instance_variable_set(:@prompts, RecordingStudioAI::Prompts::Registry.new)
    return unless RecordingStudioAI.instance_variable_defined?(:@prompt_methods)

    RecordingStudioAI.remove_instance_variable(:@prompt_methods)
  end

  def restore_prompt_registry!
    return unless instance_variable_defined?(:@original_prompts)

    RecordingStudioAI.instance_variable_set(:@prompts, @original_prompts)
    if @original_prompt_methods
      RecordingStudioAI.instance_variable_set(:@prompt_methods, @original_prompt_methods)
    elsif RecordingStudioAI.instance_variable_defined?(:@prompt_methods)
      RecordingStudioAI.remove_instance_variable(:@prompt_methods)
    end
  end

  def create_metric_run(status:, created_at: Time.current, started_at: nil, error_category: nil)
    run = RecordingStudioAI::Run.create!(
      operation: "generation",
      status: status,
      root_recording_id: @root.id,
      initiator_type: "User",
      initiator_id: @initiator.id,
      initiator_kind: "user",
      error_category: error_category,
      started_at: started_at,
      created_at: created_at
    )
    run.update_columns(created_at: created_at, started_at: started_at)
    run
  end

  def execute_metric(identifier, **params)
    RecordingStudioMetrics.execute(identifier, context: metrics_context, cache: false, **params)
  end

  def metrics_context
    RecordingStudioMetrics::Context.new(
      scope: :site,
      actor: @initiator,
      site_authorized: true,
      timezone: "UTC",
      timestamp: Time.current
    )
  end

  def access_context(actor)
    Struct.new(:access_grant).new(Struct.new(:actor).new(actor))
  end

  def without_constant(name)
    hidden = Object.const_defined?(name, false)
    value = Object.send(:remove_const, name) if hidden
    yield
  ensure
    Object.const_set(name, value) if hidden && !Object.const_defined?(name, false)
  end

  def with_admin_configuration(&)
    if Object.const_defined?(:RecordingStudioAdmin, false)
      yield_existing_admin(&)
    else
      yield_temporary_admin(&)
    end
  end

  def yield_existing_admin
    config = RecordingStudioAdmin.configuration
    original_site = config.site_admin_recording_resolver
    original_access = config.access_recording_resolver
    yield config
  ensure
    config.site_admin_recording_resolver = original_site
    config.access_recording_resolver = original_access
  end

  def yield_temporary_admin
    config = Struct.new(:site_admin_recording_resolver, :access_recording_resolver).new
    admin = Module.new
    admin.define_singleton_method(:configuration) { config }
    Object.const_set(:RecordingStudioAdmin, admin)
    yield config
  ensure
    Object.send(:remove_const, :RecordingStudioAdmin) if Object.const_defined?(:RecordingStudioAdmin, false)
  end

  def install_accessible_double
    accessible = Module.new
    accessible.define_singleton_method(:authorized?) do |actor:, recording:, role:|
      !actor.nil? && !recording.nil? && role == :view
    end
    Object.const_set(:RecordingStudioAccessible, accessible)
  end

  def remove_accessible_double
    return unless Object.const_defined?(:RecordingStudioAccessible, false)

    Object.send(:remove_const, :RecordingStudioAccessible)
  end

  def prompt_attributes(overrides = {})
    {
      owner: "Host",
      key: :gap_prompt,
      version: 1,
      name: "Gap prompt",
      description: "Coverage prompt.",
      inputs: %i[customer_name message],
      messages: [{ role: "user", content: "{{customer_name}}: {{message}}" }],
      tools: [],
      defaults: { profile: :medium, purpose: "gap_prompt" },
      overridable: true
    }.merge(overrides)
  end

  def prompt_inputs
    { customer_name: "Ada", message: "Hello" }
  end

  def attribution
    { root_recording: @root, initiator: @initiator }
  end

  def register_invocation(tools: [])
    RecordingStudioAI.prompts.register(**prompt_attributes(tools: tools))
    RecordingStudioAI.prompt(:gap_prompt)
  end

  def register_gap_tool(key)
    RecordingStudioAI.tools.register(
      key: key,
      version: 1,
      name: key.to_s,
      description: "Gap tool.",
      use_when: "Testing.",
      do_not_use_when: "Never.",
      parameters: [],
      returns: "A result.",
      cost: :low,
      latency: :fast,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Gap.#{key}",
      executor: ->(_arguments, _context) { { ok: true } }
    )
  end

  def register_counted_tool(parameters:)
    RecordingStudioAI.tools.register(
      key: :gap_tool,
      version: 1,
      name: "Gap tool",
      description: "Counts.",
      use_when: "Testing.",
      do_not_use_when: "Never.",
      parameters: parameters,
      returns: "A count.",
      cost: :low,
      latency: :fast,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Gap.count",
      executor: ->(_arguments, _context) { { ok: true } }
    )
  end

  def install_capturing_provider
    provider = CapturingProvider.new
    configuration = RecordingStudioAI.configuration
    configuration.providers = { gap: provider }
    configuration.profiles[:medium] = [
      { provider: :gap, model: "gap-model", capabilities: %i[generation streaming custom_tools] }
    ]
    provider
  end

  def tool_keys(provider, operation)
    call = provider.requests.find { |entry| entry.fetch(:operation) == operation }
    call.fetch(:request).fetch(:custom_tools).map { |tool| tool.fetch(:key) }
  end

  def install_hosted_adapter
    adapter = GapHostedAdapter.new
    RecordingStudioAI.register_provider(:openai, adapter)
    adapter
  end

  def create_hosted_session
    RecordingStudioAI::Agents.create_session(
      instructions: "Be brief.",
      input: "Hello",
      idempotency_key: "gap-create-1",
      purpose: "agent_chat",
      profile: :low,
      root_recording: @root,
      initiator: @initiator
    )
  end

  def hosted_failure(category, code, message)
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: category, code: code, message: message, retryable: category == "timeout"
    )
    RecordingStudioAI::Providers::HostedAgentFailure.new(error)
  end

  def assert_prompt_rejected(fragment, &)
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError, &)
    assert_equal "invalid_request", error.code
    assert_includes error.message, fragment
    assert_nil RecordingStudioAI.prompts.fetch(:gap_prompt)
  end

  def assert_invocation_invalid(fragment, &)
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError, &)
    assert_equal "invalid_request", error.code
    assert_includes error.message, fragment
  end

  def assert_tool_rejected(fragment, &)
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError, &)
    assert_equal "invalid_request", error.code
    assert_includes error.message, fragment
    assert_nil RecordingStudioAI.tools.fetch(:gap_tool)
  end

  def argument_error(&)
    assert_raises(RecordingStudioAI::Errors::ContractValidationError, &)
  end

  def assert_configuration_invalid(fragment)
    configuration = RecordingStudioAI::Configuration.new
    yield configuration
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { configuration.validate! }
    assert_equal "configuration", error.code
    assert_includes error.message, fragment
  end

  def with_recording_double
    raise "RecordingStudio::Recording is already defined" if RecordingStudio.const_defined?(:Recording, false)

    lookup = {}
    recording_class = Class.new do
      attr_accessor :id, :parent_recording_id, :root_recording_id

      def initialize(id:, parent_recording_id:, root_recording_id:)
        @id = id
        @parent_recording_id = parent_recording_id
        @root_recording_id = root_recording_id
      end
    end
    recording_class.define_singleton_method(:find_by) { |id:| lookup[id] }
    recording_class.define_singleton_method(:remember) { |recording| lookup[recording.id] = recording }
    RecordingStudio.const_set(:Recording, recording_class)
    yield recording_class
  ensure
    RecordingStudio.send(:remove_const, :Recording) if RecordingStudio.const_defined?(:Recording, false)
  end
end
