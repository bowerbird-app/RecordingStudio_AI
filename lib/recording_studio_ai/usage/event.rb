# frozen_string_literal: true

module RecordingStudioAI
  module Usage
    class Event
      READERS = %i[
        attribution operation provider model profile purpose provider_native_tools quantity idempotency_key metadata
      ].freeze

      attr_reader(*READERS)

      def self.for_attempt(attempt, attribution:, operation:, purpose:, provider_native_tools:)
        assemble(
          subject: attempt, id_label: "attempt", attribution: attribution, operation: operation.to_s,
          purpose: purpose, tools: provider_native_tools, quantity: 1, idempotency_key: "ai-attempt:#{attempt.id}",
          extra: { ai_run_id: attempt.run_id, attempt_id: attempt.id, attempt_kind: attempt.kind }
        )
      end

      def self.for_batch_submission(batch, attribution:, provider_native_tools:)
        assemble(
          subject: batch, id_label: "batch", attribution: attribution, operation: "batch", purpose: nil,
          tools: provider_native_tools, quantity: batch.item_count,
          idempotency_key: "ai-batch:#{batch.id}:submission", extra: { batch_id: batch.id }
        )
      end

      def self.for_hosted_agent_turn(run, attribution:)
        assemble(
          subject: run, id_label: "run", attribution: attribution, operation: "hosted_agent",
          purpose: run.purpose, tools: [], quantity: run.total_tokens.to_i,
          idempotency_key: "ai-hosted-agent-turn:#{run.provider_turn_id}",
          extra: hosted_turn_extra(run), snapshot: hosted_turn_snapshot(run)
        )
      end

      def resolver_arguments
        { attribution:, operation:, provider:, model:, profile:, purpose:, provider_native_tools: }
      end

      def handler_arguments(key)
        { key:, quantity:, attribution:, idempotency_key:, metadata: }
      end

      def require_subject_id!
        return if @subject.id

        Usage.send(:request_error!, @missing_id_message)
      end

      class << self
        private

        def assemble(options)
          tools = Usage.send(:normalize_provider_native_tools, options.fetch(:tools))
          snapshot = options[:snapshot] || string_snapshot(options.fetch(:subject), options.fetch(:operation))
          new(charge_fields(options, tools, snapshot))
        end

        def charge_fields(options, tools, snapshot)
          snapshot.merge(
            subject: options.fetch(:subject),
            missing_id_message: "#{options.fetch(:id_label)} id is required",
            attribution: options.fetch(:attribution),
            purpose: options.fetch(:purpose),
            provider_native_tools: tools,
            quantity: options.fetch(:quantity),
            idempotency_key: options.fetch(:idempotency_key),
            metadata: charge_metadata(snapshot, options.fetch(:purpose), tools, options.fetch(:extra))
          )
        end

        def charge_metadata(snapshot, purpose, tools, extra)
          { **snapshot, purpose: purpose, **extra, provider_native_tools: tools.map(&:to_s).freeze }.freeze
        end

        def hosted_turn_extra(run)
          {
            ai_run_id: run.id,
            provider_session_id: run.provider_session_id,
            provider_turn_id: run.provider_turn_id
          }
        end

        def hosted_turn_snapshot(run)
          {
            operation: "hosted_agent",
            provider: run.resolved_provider.to_s,
            model: run.resolved_model.to_s,
            profile: run.profile_key&.to_s
          }
        end

        def string_snapshot(record, operation)
          { operation: operation, provider: record.provider.to_s, model: record.model.to_s,
            profile: record.profile_key&.to_s }
        end
      end

      private_class_method :new

      def initialize(attributes)
        @subject = attributes.fetch(:subject)
        @missing_id_message = attributes.fetch(:missing_id_message)
        READERS.each { |name| instance_variable_set(:"@#{name}", attributes.fetch(name)) }
      end
    end
  end
end
