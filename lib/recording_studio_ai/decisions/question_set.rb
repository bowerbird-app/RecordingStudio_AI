# frozen_string_literal: true

module RecordingStudioAI
  module Decisions
    QuestionEntry = Data.define(:key, :question)

    class QuestionSet
      include Enumerable

      QUESTION_KEYS = %i[type instructions criteria].freeze

      attr_reader :entries

      class << self
        def parse(value)
          Decisions.validation_error!("questions must be a non-empty Hash") unless value.is_a?(Hash) && value.any?

          entries = value.map { |key, question| parse_entry(key, question) }
          Decisions.reject_key_collisions!(entries.map(&:key), path: "questions")
          new(entries: entries)
        end

        private

        def parse_entry(key, question)
          QuestionEntry.new(
            key: Decisions.key_for(key, path: "questions"),
            question: parse_question(question, key: key)
          )
        end

        def parse_question(value, key:)
          return value if value.is_a?(Question)

          unless value.is_a?(Hash)
            Decisions.validation_error!("questions[#{key}] must be a Hash or a Decisions question")
          end

          attributes = value.transform_keys(&:to_sym)
          unknown = attributes.keys - QUESTION_KEYS
          Decisions.validation_error!("questions[#{key}] contains unknown keys: #{unknown.join(', ')}") if unknown.any?

          build_question(attributes, key: key)
        end

        def build_question(attributes, key:)
          case attributes[:type].to_s
          when "choice"
            Choice.new(instructions: attributes[:instructions], criteria: attributes[:criteria])
          when "score"
            Score.new(instructions: attributes[:instructions], criteria: attributes[:criteria])
          when "noul"
            Noul.new(instructions: attributes[:instructions], criteria: attributes[:criteria])
          else
            Decisions.validation_error!("questions[#{key}].type must be one of: #{QUESTION_TYPES.join(', ')}")
          end
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

      def types
        entries.map { |entry| entry.question.type }.uniq.freeze
      end

      def canonical_keys
        entries.map { |entry| entry.key.canonical_key }
      end

      def fetch_canonical(canonical_key)
        entries.find { |entry| entry.key.canonical_key == canonical_key }
      end
    end
  end
end
