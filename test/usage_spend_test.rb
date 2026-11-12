# frozen_string_literal: true

require "test_helper"

class UsageSpendTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class QueueProvider < RecordingStudioAI::Providers::Base
    attr_reader :calls
    attr_accessor :on_call

    def initialize(*results)
      super()
      @results = results
      @calls = []
    end

    def generate(request:, candidate:)
      on_call&.call
      calls << { request: request, candidate: candidate }
      result = @results.shift || raise("unexpected provider call")
      raise result if result.is_a?(Exception)

      result
    end
  end

  class StreamProbe < RecordingStudioAI::Providers::Base
    attr_reader :calls

    def initialize
      super
      @calls = []
    end

    def stream(request:, candidate:)
      calls << { request: request, candidate: candidate }
      yield RecordingStudioAI::Providers::StreamEvent.new(type: :text_delta, text_delta: "nope")
      RecordingStudioAI::Providers::Result.new(text: "nope", finish_reason: "stop")
    end
  end

  class DecisionProbe < RecordingStudioAI::Providers::Base
    attr_reader :calls

    def initialize
      super
      @calls = []
    end

    def decide(request:, candidate:)
      calls << { request: request, candidate: candidate }
      question_set = request.fetch(:questions)
      RecordingStudioAI::Providers::DecisionResult.new(
        answers: RecordingStudioAI::Decisions::AnswerSet.from_canonical(
          question_set: question_set,
          answers: {
            question_set.canonical_keys.fetch(0) => RecordingStudioAI::Decisions::NoulAnswer.new(probability: 0.4)
          }
        )
      )
    end
  end

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(51)
    isolate_allow_all_configuration!
  end

  def test_missing_handler_skips_billing_and_still_aggregates_usage
    provider = QueueProvider.new(success_result("Done", usage: usage(10, 5), cost: cost(40)))
    configure_single_candidate(:medium, :catalog_provider, provider)

    response = generate

    assert_predicate response, :success?
    assert_equal "Done", response.text
    assert_equal 1, provider.calls.length
    assert_equal 10, response.usage.input_tokens
    assert_equal 5, response.usage.output_tokens
    assert_equal 15, response.usage.total_tokens
    assert_equal 40, response.cost.amount
    refute response.cost.estimated?
  end

  def test_attempt_without_usage_skips_the_charge_and_calls_the_provider
    handler_calls = 0
    assign_meter([])
    RecordingStudioAI.configuration.usage_handler = lambda do |**|
      handler_calls += 1
      raise "handler must not run"
    end
    provider = QueueProvider.new(success_result("Done"))
    configure_single_candidate(:medium, :first, provider)

    response = generate

    assert_predicate response, :success?
    assert_equal 0, handler_calls
    assert_equal 1, provider.calls.length
  end

  def test_handler_charges_after_the_provider_from_reported_usage
    order = []
    seen = []
    assign_meter(seen)
    RecordingStudioAI.configuration.usage_precheck = lambda do |**|
      order << :precheck
      true
    end
    RecordingStudioAI.configuration.usage_handler = lambda do |**kwargs|
      order << :handler
      seen << kwargs
    end
    provider = QueueProvider.new(success_result("Done", usage: usage(12, 8)))
    provider.on_call = -> { order << :provider }
    configure_single_candidate(:medium, :gemini, provider)

    response = generate(metadata: { leak: "hidden-note" })

    assert_predicate response, :success?
    assert_equal %i[precheck provider handler], order
    attempt = RecordingStudioAI::Attempt.sole
    spend = seen.sole
    assert_equal 20, spend.fetch(:credits)
    assert_same @root_recording, spend.fetch(:attribution).root_recording
    assert_equal "ai-attempt:#{attempt.id}", spend.fetch(:idempotency_key)
    assert_equal "gemini", spend.dig(:breakdown, :provider)
    assert_equal "gemini-model", spend.dig(:breakdown, :model)
    assert_equal({ input: 12, output: 8 }, spend.dig(:breakdown, :counts))
    assert spend.fetch(:breakdown).frozen?
    refute_includes spend.fetch(:breakdown).inspect, "Resilient request"
    refute_includes spend.fetch(:breakdown).inspect, "hidden-note"
  end

  def test_handler_refusal_fails_the_attempt_without_calling_the_provider
    provider = QueueProvider.new(success_result("must not run"))
    configure_single_candidate(:medium, :first, provider)
    RecordingStudioAI.configuration.credit_prices = { "*" => { input: 1 } }
    RecordingStudioAI.configuration.usage_precheck = ->(**) { raise "credits exhausted" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }

    error = assert_raises(RuntimeError) { generate }

    assert_equal "credits exhausted", error.message
    assert_empty provider.calls
    attempt = RecordingStudioAI::Attempt.sole
    run = RecordingStudioAI::Run.sole
    assert_equal "failed", attempt.status
    assert_equal false, attempt.retryable
    assert_equal "usage", attempt.error_category
    assert_equal "usage_declined", attempt.error_code
    assert_equal "credits exhausted", attempt.error_message
    assert_equal "failed", run.status
    assert_equal "usage", run.error_category
    assert_equal "usage_declined", run.error_code
    assert_equal "credits exhausted", run.error_message
    refute_equal "provider_execution_error", attempt.error_code
    refute_equal "provider_execution_error", run.error_code
  end

  def test_long_usage_refusal_message_is_truncated_to_255_characters
    provider = QueueProvider.new(success_result("must not run"))
    configure_single_candidate(:medium, :first, provider)
    message = "x" * 300
    RecordingStudioAI.configuration.credit_prices = { "*" => { input: 1 } }
    RecordingStudioAI.configuration.usage_precheck = ->(**) { raise message }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }

    error = assert_raises(RuntimeError) { generate }

    assert_equal message, error.message
    assert_equal message[0, 255], RecordingStudioAI::Attempt.sole.error_message
    assert_equal message[0, 255], RecordingStudioAI::Run.sole.error_message
  end

  def test_retry_then_fallback_spends_once_per_attempt_and_sums_tokens
    configuration = RecordingStudioAI.configuration
    configuration.maximum_attempts = 3
    configuration.maximum_retries_per_candidate = 1
    configuration.maximum_provider_fallbacks = 1
    spends = []
    assign_meter(spends)
    first_provider = QueueProvider.new(
      failed_result("rate_limit", usage: usage(10, 0), cost: cost(100)),
      failed_result("timeout", usage: usage(4, 0), cost: cost(40))
    )
    second_provider = QueueProvider.new(
      success_result("Fallback answer", usage: usage(8, 6), cost: cost(90))
    )
    configure_candidates(first: first_provider, second: second_provider, profile: :medium)

    response = generate

    assert_predicate response, :success?
    assert_equal "Fallback answer", response.text
    assert_equal 22, response.usage.input_tokens
    assert_equal 6, response.usage.output_tokens
    assert_equal 28, response.usage.total_tokens
    assert_equal 230, response.cost.amount
    assert_equal 3, spends.length
    assert_equal([10, 4, 14], spends.map { |spend| spend.fetch(:credits) })
    keys = spends.map { |spend| spend.fetch(:idempotency_key) }
    assert_equal keys.uniq, keys
    attempt_ids = RecordingStudioAI::Attempt.order(:sequence).pluck(:id)
    assert_equal attempt_ids.map { |id| "ai-attempt:#{id}" }, keys
  end

  def test_spend_twice_on_the_same_persisted_attempt_reuses_the_idempotency_key
    provider = QueueProvider.new(success_result("Done"))
    configure_single_candidate(:medium, :first, provider)
    generate
    attempt = RecordingStudioAI::Attempt.sole
    spends = []
    assign_meter(spends)

    result = success_result("Done", usage: usage(3, 1))
    2.times do
      assert charge_on(attempt, result)
    end

    assert_equal 2, spends.length
    assert_equal([4, 4], spends.map { |spend| spend.fetch(:credits) })
    assert_equal(
      ["ai-attempt:#{attempt.id}", "ai-attempt:#{attempt.id}"],
      spends.map { |spend| spend.fetch(:idempotency_key) }
    )
  end

  def test_decide_spends_once_for_the_decision_operation
    provider = DecisionProbe.new
    configure_single_candidate(
      :medium, :decisive, provider, capabilities: %i[decision decision_noul]
    )
    spends = []
    assign_meter(spends)

    response = RecordingStudioAI.decide(
      state: "Notes.",
      questions: { mentioned: { type: :noul, instructions: "Is the target mentioned?" } },
      profile: :medium,
      purpose: "coverage_triage",
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_predicate response, :success?
    assert_equal "decision", response.operation
    assert_equal 1, provider.calls.length
    assert_equal 1, spends.length
    assert_equal "decisive", spends.sole.dig(:breakdown, :provider)
    assert_equal({ decision: 1 }, spends.sole.dig(:breakdown, :counts))
    assert_equal 1, spends.sole.fetch(:credits)
    refute_includes spends.sole.fetch(:breakdown).inspect, "Notes."
  end

  def test_provider_error_after_a_successful_spend_stays_a_provider_failure
    spends = []
    assign_meter(spends)
    provider = QueueProvider.new(RuntimeError.new("provider exploded"))
    configure_single_candidate(:medium, :first, provider)

    response = generate

    refute_predicate response, :success?
    assert_equal "provider_execution_error", response.error.code
    assert_equal "provider_error", response.error.category
    assert_equal 1, provider.calls.length
    assert_empty spends
    assert_equal "failed", response.run.status
    assert_equal "provider_execution_error", response.run.error_code
  end

  def test_perform_tool_does_not_call_the_usage_handler
    isolate_tools_registry!
    register_echo
    RecordingStudioAI.configuration.credit_prices = { "*" => { input: 1 } }
    RecordingStudioAI.configuration.usage_precheck = ->(**) { raise "precheck must not run" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "usage handler must not run" }

    performance = RecordingStudioAI.perform_tool!(
      tool: { key: :echo_text, version: 1 },
      arguments: { text: "argument-body" },
      purpose: "agent_step",
      root_recording: @root_recording,
      initiator: @initiator,
      request_id: "step-1"
    )

    assert_predicate performance, :success?
    assert_equal({ "echo" => "argument-body" }, performance.result)
  end

  def test_stream_usage_refusal_stays_usage_declined
    provider = StreamProbe.new
    configure_single_candidate(:medium, :test, provider, capabilities: %i[generation streaming])
    RecordingStudioAI.configuration.credit_prices = { "*" => { input: 1 } }
    RecordingStudioAI.configuration.usage_precheck = ->(**) { raise "credits exhausted" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }
    events = []

    error = assert_raises(RuntimeError) { stream { |event| events << event } }

    assert_equal "credits exhausted", error.message
    assert_empty events
    assert_empty provider.calls
    attempt = RecordingStudioAI::Attempt.sole
    run = attempt.run.reload
    assert_equal "failed", attempt.reload.status
    assert_equal "usage_declined", attempt.error_code
    assert_equal "failed", run.status
    assert_equal "usage_declined", run.error_code
    refute_equal "stream_cancelled", attempt.error_code
    refute_equal "stream_cancelled", run.error_code
  end

  def test_custom_tool_continuation_spends_twice_and_skips_the_local_tool
    isolate_tools_registry!
    tool_runs = 0
    spends = []
    assign_meter(spends)
    provider = QueueProvider.new(
      tool_result("call-1", "echo_text", { "text" => "hello" }, usage: usage(2, 0)),
      success_result("continued", usage: usage(1, 3))
    )
    configure_single_candidate(:medium, :first, provider, capabilities: %i[generation custom_tools])
    register_echo(executor: lambda { |arguments, _context|
      tool_runs += 1
      { "echo" => arguments.fetch("text") }
    })

    response = generate(custom_tools: [{ key: :echo_text, version: 1 }])

    assert_predicate response, :success?
    assert_equal "continued", response.text
    assert_equal 1, tool_runs
    assert_equal 2, provider.calls.length
    assert_equal %w[primary continuation], response.attempts.map(&:kind)
    assert_equal 2, spends.length
    assert_equal([2, 4], spends.map { |spend| spend.fetch(:credits) })
    keys = spends.map { |spend| spend.fetch(:idempotency_key) }
    assert_equal 2, keys.uniq.length
    attempt_ids = RecordingStudioAI::Attempt.order(:sequence).pluck(:id)
    assert_equal attempt_ids.map { |id| "ai-attempt:#{id}" }, keys
  end

  def test_precheck_false_blocks_the_provider
    provider = QueueProvider.new(success_result("must not run"))
    configure_single_candidate(:medium, :first, provider)
    assign_meter([])
    RecordingStudioAI.configuration.usage_precheck = ->(**) { false }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { generate }

    assert_equal "Not enough credits for this call.", error.message
    assert_empty provider.calls
    assert_equal "usage_declined", RecordingStudioAI::Attempt.sole.error_code
  end

  def test_missing_attempt_id_is_rejected_before_the_handler
    assign_meter([])
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      spend_on(meter_attempt(id: nil))
    end

    assert_equal "invalid_request", error.code
  end

  def test_charge_ignores_the_handler_return_value
    attempt = meter_attempt
    assign_meter([])
    RecordingStudioAI.configuration.usage_handler = ->(**) { :billed }

    assert spend_on(attempt)
  end

  def test_reported_web_search_is_priced_and_the_prompt_stays_out_of_the_breakdown
    spends = []
    assign_meter(spends)
    searched = usage(4, 2).with_count(:web_search, 2)
    provider = QueueProvider.new(success_result("Searched", usage: searched))
    configure_single_candidate(
      :medium, :gemini, provider, capabilities: %i[generation provider_native_web_search]
    )

    response = generate(prompt: "What shipped this week?", provider_native_tools: [:web_search])

    assert_predicate response, :success?
    spend = spends.sole
    assert_equal({ input: 4, output: 2, web_search: 2 }, spend.dig(:breakdown, :counts))
    assert_equal 8, spend.fetch(:credits)
    assert_equal "gemini-model", spend.dig(:breakdown, :model)
    refute_includes spend.fetch(:breakdown).inspect, "What shipped this week?"
  end

  def test_prompt_and_tool_extras_are_applied_once
    isolate_tools_registry!
    original_prompts = RecordingStudioAI.instance_variable_get(:@prompts)
    RecordingStudioAI.instance_variable_set(:@prompts, RecordingStudioAI::Prompts::Registry.new)
    spends = []
    assign_meter(spends)
    register_echo(credit_fee: 1, credit_multiplier: 2)
    prompt = RecordingStudioAI.prompts.register(
      key: :billing_note, version: 1, name: "Billing note", description: "A short note.",
      inputs: [], messages: [{ role: "user", content: "Hello there" }],
      credit_fee: 3, credit_multiplier: 2
    )
    provider = QueueProvider.new(success_result("Done", usage: usage(1, 0)))
    configure_single_candidate(:medium, :first, provider, capabilities: %i[generation custom_tools])

    response = generate(
      prompt: "Hello there",
      prompt_definition: prompt,
      custom_tools: [{ key: :echo_text, version: 1 }]
    )

    assert_predicate response, :success?
    # 1 input credit, times 2 prompt and 2 tool, plus fees 3 and 1, then one round up.
    assert_equal 8, spends.sole.fetch(:credits)
    assert_equal "billing_note", spends.sole.dig(:breakdown, :extras, :prompt_key)
    assert_equal ["echo_text"], spends.sole.dig(:breakdown, :extras, :tool_keys)
    refute_includes spends.sole.fetch(:breakdown).inspect, "Hello there"
  ensure
    RecordingStudioAI.instance_variable_set(:@prompts, original_prompts) if original_prompts
  end

  def test_nil_handler_does_not_charge_a_missing_id
    RecordingStudioAI.configuration.usage_handler = nil

    assert_nil spend_on(meter_attempt(id: nil))
  end

  def test_usage_is_a_legal_normalized_error_category
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "usage", code: "usage_declined", message: "credits exhausted", retryable: false
    )

    assert_equal "usage", error.category
    assert_equal "usage_declined", error.code
  end

  def test_library_and_gemspec_do_not_name_the_billing_gem
    forbidden = %w[Recording Studio Stripe].join
    root = File.expand_path("..", __dir__)
    files = Dir.glob(File.join(root, "lib/**/*.rb"))
    files << File.join(root, "recording_studio_ai.gemspec")

    files.each do |path|
      refute_includes File.read(path), forbidden, path
    end
  end

  private

  def generate(**overrides)
    RecordingStudioAI.generate(
      prompt: "Resilient request",
      root_recording: @root_recording,
      initiator: @initiator,
      **overrides
    )
  end

  def stream(&)
    RecordingStudioAI.generate(
      stream: true,
      prompt: "Resilient request",
      root_recording: @root_recording,
      initiator: @initiator,
      &
    )
  end

  def configure_candidates(first:, second:, profile:)
    configuration = RecordingStudioAI.configuration
    configuration.providers = { first: first, second: second }
    configuration.profiles[profile] = [
      { provider: :first, model: "first-model", capabilities: %i[generation] },
      { provider: :second, model: "second-model", capabilities: %i[generation] }
    ]
  end

  def configure_single_candidate(profile, provider_key, provider, capabilities: %i[generation])
    configuration = RecordingStudioAI.configuration
    configuration.providers[provider_key] = provider
    configuration.profiles[profile] = [
      { provider: provider_key, model: "#{provider_key}-model", capabilities: capabilities }
    ]
  end

  def assign_meter(bucket, precheck: ->(**) { true })
    configuration = RecordingStudioAI.configuration
    configuration.credit_prices = {
      "*" => {
        input: 1_000_000, output: 1_000_000, cached_input: 1_000_000,
        reasoning: 1_000_000, web_search: 1, decision: 1
      }
    }
    configuration.usage_precheck = precheck
    configuration.usage_handler = lambda do |**kwargs|
      bucket << kwargs
    end
  end

  def charge_on(attempt, result, operation: :generation)
    RecordingStudioAI::Usage.charge_attempt!(
      attempt: attempt,
      result: result,
      request: { attribution: attribution },
      operation: operation
    )
  end

  def success_result(text, usage: nil, cost: nil)
    RecordingStudioAI::Providers::Result.new(
      text: text,
      usage: usage,
      cost: cost,
      finish_reason: "stop"
    )
  end

  def failed_result(category, retryable: true, usage: nil, cost: nil)
    RecordingStudioAI::Providers::Result.new(
      usage: usage,
      cost: cost,
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: category,
        code: category,
        message: "Provider failed.",
        retryable: retryable,
        provider: "first"
      )
    )
  end

  def tool_result(call_id, key, arguments, usage: nil)
    RecordingStudioAI::Providers::Result.new(
      usage: usage,
      tool_calls: [
        RecordingStudioAI::Providers::ToolCall.new(
          provider_tool_call_id: call_id,
          key: key,
          arguments: arguments
        )
      ],
      finish_reason: "tool_calls"
    )
  end

  def usage(input_tokens, output_tokens)
    RecordingStudioAI::Contracts::Usage.new(
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    )
  end

  def cost(amount, currency: "USD")
    RecordingStudioAI::Contracts::Cost.new(
      amount: amount,
      currency: currency,
      estimated: false,
      source: "provider"
    )
  end

  def meter_attempt(id: 41)
    Struct.new(:id, :provider, :model, :profile_key, :run_id, :kind, keyword_init: true).new(
      id: id,
      provider: "gemini",
      model: "gemini-2.5-flash",
      profile_key: "low",
      run_id: 9,
      kind: "primary"
    )
  end

  def spend_on(attempt)
    charge_on(attempt, success_result("Done", usage: usage(2, 2)))
  end

  def attribution
    RecordingStudioAI::Contracts::Attribution.new(
      root_recording: @root_recording,
      initiator: @initiator
    )
  end

  def register_echo(executor: nil, credit_fee: 0, credit_multiplier: 1)
    supplied = executor
    RecordingStudioAI.tools.register(
      key: :echo_text,
      version: 1,
      name: "Echo text",
      description: "Returns the text it was given.",
      use_when: "The caller wants the text back.",
      do_not_use_when: "The text is empty.",
      parameters: [
        { name: :text, type: :string, required: true, description: "Text to echo." }
      ],
      returns: "The echoed text.",
      cost: :negligible,
      latency: :instant,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      credit_fee: credit_fee,
      credit_multiplier: credit_multiplier,
      executor_label: "Echo.text",
      executor: lambda { |arguments, context|
        if supplied
          supplied.call(arguments, context)
        else
          { "echo" => arguments.fetch("text") }
        end
      }
    )
  end
end
