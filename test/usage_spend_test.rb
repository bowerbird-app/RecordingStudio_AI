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

  def test_missing_handler_skips_the_resolver_and_still_aggregates_usage
    resolver_calls = 0
    RecordingStudioAI.configuration.usage_key_resolver = lambda do |**|
      resolver_calls += 1
      raise "resolver must not run"
    end
    provider = QueueProvider.new(success_result("Done", usage: usage(10, 5), cost: cost(40)))
    configure_single_candidate(:medium, :catalog_provider, provider)

    response = generate

    assert_predicate response, :success?
    assert_equal "Done", response.text
    assert_equal 1, provider.calls.length
    assert_equal 0, resolver_calls
    assert_equal 10, response.usage.input_tokens
    assert_equal 5, response.usage.output_tokens
    assert_equal 15, response.usage.total_tokens
    assert_equal 40, response.cost.amount
    refute response.cost.estimated?
  end

  def test_nil_usage_key_skips_the_handler_and_calls_the_provider
    handler_calls = 0
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) {}
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

  def test_handler_runs_before_the_provider_with_meter_metadata
    order = []
    seen = []
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.gemini_flash" }
    RecordingStudioAI.configuration.usage_handler = lambda do |key:, quantity:, attribution:,
                                                              idempotency_key:, metadata:|
      order << :handler
      seen << {
        key: key,
        quantity: quantity,
        attribution: attribution,
        idempotency_key: idempotency_key,
        metadata: metadata
      }
    end
    provider = QueueProvider.new(success_result("Done"))
    provider.on_call = -> { order << :provider }
    configure_single_candidate(:medium, :gemini, provider)

    response = generate(metadata: { leak: "hidden-note" })

    assert_predicate response, :success?
    assert_equal %i[handler provider], order
    attempt = RecordingStudioAI::Attempt.sole
    spend = seen.sole
    assert_equal "ai.gemini_flash", spend.fetch(:key)
    assert_equal 1, spend.fetch(:quantity)
    assert_same @root_recording, spend.fetch(:attribution).root_recording
    assert_equal "ai-attempt:#{attempt.id}", spend.fetch(:idempotency_key)
    assert_equal "gemini", spend.dig(:metadata, :provider)
    assert_equal "gemini-model", spend.dig(:metadata, :model)
    assert spend.fetch(:metadata).frozen?
    assert_equal(
      {
        operation: "generation",
        provider: "gemini",
        model: "gemini-model",
        profile: "medium",
        purpose: nil,
        ai_run_id: attempt.run_id,
        attempt_id: attempt.id,
        attempt_kind: "primary"
      },
      spend.fetch(:metadata)
    )
    values = spend.fetch(:metadata).values.map(&:to_s)
    refute(values.any? { |value| value.include?("Resilient request") })
    refute(values.any? { |value| value.include?("hidden-note") })
  end

  def test_handler_refusal_fails_the_attempt_without_calling_the_provider
    provider = QueueProvider.new(success_result("must not run"))
    configure_single_candidate(:medium, :first, provider)
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.openai" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "credits exhausted" }

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
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.openai" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise message }

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
    assert_equal([1, 1, 1], spends.map { |spend| spend.fetch(:quantity) })
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

    2.times do
      assert_nil RecordingStudioAI::Usage.spend!(
        attempt: attempt,
        attribution: attribution,
        operation: :generation
      )
    end

    assert_equal 2, spends.length
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
    assign_meter(spends, key: "ai.jev")

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
    assert_equal "decision", spends.sole.dig(:metadata, :operation)
    assert_equal "decisive", spends.sole.dig(:metadata, :provider)
    assert_equal "coverage_triage", spends.sole.dig(:metadata, :purpose)
    assert_equal 1, spends.sole.fetch(:quantity)
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
    assert_equal 1, spends.length
    assert_equal "failed", response.run.status
    assert_equal "provider_execution_error", response.run.error_code
  end

  def test_perform_tool_does_not_call_the_usage_handler
    isolate_tools_registry!
    register_echo
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.tool" }
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
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { "ai.stream" }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "credits exhausted" }
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
      tool_result("call-1", "echo_text", { "text" => "hello" }),
      success_result("continued")
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
    assert_equal([1, 1], spends.map { |spend| spend.fetch(:quantity) })
    keys = spends.map { |spend| spend.fetch(:idempotency_key) }
    assert_equal 2, keys.uniq.length
    attempt_ids = RecordingStudioAI::Attempt.order(:sequence).pluck(:id)
    assert_equal attempt_ids.map { |id| "ai-attempt:#{id}" }, keys
  end

  def test_spend_rejects_blank_and_non_string_keys_before_the_handler
    attempt = meter_attempt
    calls = []
    RecordingStudioAI.configuration.usage_handler = ->(**kwargs) { calls << kwargs }

    ["", "   ", 4].each do |key|
      RecordingStudioAI.configuration.usage_key_resolver = ->(**) { key }
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { spend_on(attempt) }

      assert_equal "configuration", error.code
    end
    assert_empty calls
  end

  def test_resolver_exception_propagates_without_calling_the_handler
    attempt = meter_attempt
    calls = []
    RecordingStudioAI.configuration.usage_handler = ->(**kwargs) { calls << kwargs }
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { raise IOError, "resolver down" }

    error = assert_raises(IOError) { spend_on(attempt) }

    assert_equal "resolver down", error.message
    assert_empty calls
  end

  def test_handler_without_a_resolver_is_rejected_before_the_handler_runs
    attempt = meter_attempt
    calls = []
    RecordingStudioAI.configuration.usage_handler = ->(**kwargs) { calls << kwargs }
    RecordingStudioAI.configuration.usage_key_resolver = nil

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { spend_on(attempt) }

    assert_equal "configuration", error.code
    assert_includes error.message, "usage_key_resolver"
    assert_empty calls
  end

  def test_missing_attempt_id_is_rejected_before_the_resolver
    seen = []
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }
    RecordingStudioAI.configuration.usage_key_resolver = lambda { |**|
      seen << :resolver
      "ai.openai"
    }

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { spend_on(meter_attempt(id: nil)) }

    assert_equal "invalid_request", error.code
    assert_empty seen
  end

  def test_symbol_usage_key_is_normalized_and_the_handler_return_is_ignored
    attempt = meter_attempt
    seen = nil
    handled = nil
    attribution = self.attribution
    RecordingStudioAI.configuration.usage_key_resolver = lambda { |**kwargs|
      seen = kwargs
      :ai_openai
    }
    RecordingStudioAI.configuration.usage_handler = lambda { |**kwargs|
      handled = kwargs
      :billed
    }

    assert_nil RecordingStudioAI::Usage.spend!(
      attempt: attempt, attribution: attribution, operation: :decision, purpose: "draft_reply"
    )

    assert_same attribution, seen.fetch(:attribution)
    assert_equal "decision", seen.fetch(:operation)
    assert_equal "gemini", seen.fetch(:provider)
    assert_equal "gemini-2.5-flash", seen.fetch(:model)
    assert_equal "low", seen.fetch(:profile)
    assert_equal "draft_reply", seen.fetch(:purpose)
    assert_equal "ai_openai", handled.fetch(:key)
    assert_equal 1, handled.fetch(:quantity)
    assert_equal "ai-attempt:41", handled.fetch(:idempotency_key)
    assert_equal "draft_reply", handled.dig(:metadata, :purpose)
    assert_equal 9, handled.dig(:metadata, :ai_run_id)
    assert handled.fetch(:metadata).frozen?
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

  def assign_meter(bucket, key: "ai.openai")
    RecordingStudioAI.configuration.usage_key_resolver = ->(**) { key }
    RecordingStudioAI.configuration.usage_handler = lambda do |**kwargs|
      bucket << kwargs
    end
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

  def tool_result(call_id, key, arguments)
    RecordingStudioAI::Providers::Result.new(
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
    RecordingStudioAI::Usage.spend!(
      attempt: attempt,
      attribution: attribution,
      operation: :generation
    )
  end

  def attribution
    RecordingStudioAI::Contracts::Attribution.new(
      root_recording: @root_recording,
      initiator: @initiator
    )
  end

  def register_echo(executor: nil)
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
