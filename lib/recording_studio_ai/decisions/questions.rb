# frozen_string_literal: true

module RecordingStudioAI
  module Decisions
    Criterion = Data.define(:key, :description)

    class Question
      attr_reader :instructions

      def initialize(instructions:)
        @instructions = Decisions.non_empty_string!(instructions, path: "question instructions")
      end

      def type
        raise NotImplementedError, "#{self.class} must implement #type"
      end
    end

    class Choice < Question
      MAXIMUM_CRITERIA = 255

      attr_reader :criteria

      def initialize(instructions:, criteria:)
        super(instructions: instructions)
        @criteria = normalize_criteria(criteria)
        freeze
      end

      def type
        :choice
      end

      def canonical_keys
        criteria.map { |criterion| criterion.key.canonical_key }
      end

      def public_choice_for(canonical_key)
        criterion = criteria.find { |candidate| candidate.key.canonical_key == canonical_key }
        criterion&.key&.public_key
      end

      private

      def normalize_criteria(value)
        Decisions.validation_error!("choice criteria must be a Hash") unless value.is_a?(Hash)
        unless value.length.between?(1, MAXIMUM_CRITERIA)
          Decisions.validation_error!("choice criteria must contain between 1 and #{MAXIMUM_CRITERIA} entries")
        end

        criteria = value.map { |key, description| normalize_criterion(key, description) }
        Decisions.reject_key_collisions!(criteria.map(&:key), path: "choice criteria")
        criteria.freeze
      end

      def normalize_criterion(key, description)
        Criterion.new(
          key: Decisions.key_for(key, path: "choice criteria"),
          description: normalize_description(description)
        )
      end

      def normalize_description(value)
        return nil if value.nil?

        Decisions.non_empty_string!(value, path: "choice criteria descriptions")
      end
    end

    class Score < Question
      MINIMUM_CRITERIA = 2
      MAXIMUM_CRITERIA = 10

      attr_reader :criteria

      def initialize(instructions:, criteria:)
        super(instructions: instructions)
        @criteria = normalize_criteria(criteria)
        freeze
      end

      def type
        :score
      end

      def maximum_score
        criteria.length - 1
      end

      private

      def normalize_criteria(value)
        Decisions.validation_error!("score criteria must be an Array") unless value.is_a?(Array)
        unless value.length.between?(MINIMUM_CRITERIA, MAXIMUM_CRITERIA)
          Decisions.validation_error!(
            "score criteria must contain between #{MINIMUM_CRITERIA} and #{MAXIMUM_CRITERIA} entries"
          )
        end

        value.map { |label| Decisions.non_empty_string!(label, path: "score criteria") }.freeze
      end
    end

    class Noul < Question
      CRITERIA_KEYS = [true, false].freeze

      attr_reader :criteria

      def initialize(instructions:, criteria: nil)
        super(instructions: instructions)
        @criteria = normalize_criteria(criteria)
        freeze
      end

      def type
        :noul
      end

      private

      def normalize_criteria(value)
        return nil if value.nil?

        Decisions.validation_error!("noul criteria must be a Hash") unless value.is_a?(Hash)
        unless value.keys.sort_by(&:to_s) == CRITERIA_KEYS.sort_by(&:to_s)
          Decisions.validation_error!("noul criteria keys must be exactly true and false")
        end

        CRITERIA_KEYS.to_h do |key|
          [key, Decisions.non_empty_string!(value[key], path: "noul criteria descriptions")]
        end.freeze
      end
    end
  end
end
