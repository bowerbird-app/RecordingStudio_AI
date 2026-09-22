# frozen_string_literal: true

module RecordingStudioAI
  module Decisions
    AnswerEntry = Data.define(:key, :answer)

    class AnswerSet
      include Enumerable

      ANSWER_CLASSES = { choice: ChoiceAnswer, score: ScoreAnswer, noul: NoulAnswer }.freeze

      attr_reader :entries

      class << self
        def from_canonical(question_set:, answers:)
          Decisions.validation_error!("answers must be a Hash") unless answers.is_a?(Hash)

          unexpected = answers.keys.map(&:to_s) - question_set.canonical_keys
          Decisions.validation_error!("answers contains unrequested keys: #{unexpected.join(', ')}") if unexpected.any?

          new(entries: question_set.map { |entry| answer_entry(entry, answers) })
        end

        def empty
          new(entries: [])
        end

        private

        def answer_entry(entry, answers)
          canonical = entry.key.canonical_key
          answer = answers[canonical]
          Decisions.validation_error!("answers is missing #{canonical}") if answer.nil?

          expected = ANSWER_CLASSES.fetch(entry.question.type)
          unless answer.is_a?(expected)
            Decisions.validation_error!("answers[#{canonical}] must be a #{expected.name.split('::').last}")
          end

          AnswerEntry.new(key: entry.key, answer: answer)
        end
      end

      def initialize(entries:)
        @entries = entries.dup.freeze
        freeze
      end

      def each(&)
        entries.each(&)
      end

      def length
        entries.length
      end

      def empty?
        entries.empty?
      end

      # Lookup is exact: a String key is never silently matched to a Symbol.
      def fetch(public_key)
        entry = entries.find { |candidate| candidate.key.public_key == public_key }
        raise KeyError, "no answer for question #{public_key.inspect}" unless entry

        entry.answer
      end

      def [](public_key)
        entries.find { |candidate| candidate.key.public_key == public_key }&.answer
      end

      def to_h
        entries.to_h { |entry| [entry.key.public_key, entry.answer] }.freeze
      end

      def to_serializable_h
        RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          entries.to_h { |entry| [entry.key.canonical_key, entry.answer.to_h] },
          path: "answers"
        )
      end
    end
  end
end
