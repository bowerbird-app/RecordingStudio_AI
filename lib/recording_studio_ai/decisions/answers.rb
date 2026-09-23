# frozen_string_literal: true

module RecordingStudioAI
  module Decisions
    module Probability
      module_function

      def parse(value, path:)
        Decisions.finite_number!(value, path: path)
        Decisions.validation_error!("#{path} must be between 0 and 1") unless value.between?(0, 1)

        value
      end

      def parse_map(value, path:)
        Decisions.validation_error!("#{path} must be a Hash") unless value.is_a?(Hash)

        value.to_h { |key, probability| [key, parse(probability, path: "#{path}[#{key}]")] }.freeze
      end
    end

    class ChoiceAnswer
      attr_reader :choice, :probabilities, :confidence

      def initialize(choice:, probabilities:, confidence:)
        @choice = choice
        @probabilities = Probability.parse_map(probabilities, path: "choice probabilities")
        @confidence = Probability.parse(confidence, path: "choice confidence")
        freeze
      end

      def type
        :choice
      end

      def to_h
        { type: "choice", choice: choice, probabilities: probabilities, confidence: confidence }
      end
    end

    class ScoreAnswer
      attr_reader :score, :legend, :probabilities, :confidence

      def initialize(score:, legend:, probabilities:, confidence:)
        @score = Decisions.finite_number!(score, path: "score")
        @legend = normalize_legend(legend)
        @probabilities = Probability.parse_map(probabilities, path: "score probabilities")
        @confidence = Probability.parse(confidence, path: "score confidence")
        freeze
      end

      def type
        :score
      end

      def to_h
        { type: "score", score: score, legend: legend, probabilities: probabilities, confidence: confidence }
      end

      private

      # Legend keys stay the string indexes the provider reports. Coercing them
      # to integers or symbols would lose the wire contract.
      def normalize_legend(value)
        Decisions.validation_error!("score legend must be a Hash") unless value.is_a?(Hash)

        value.to_h do |index, label|
          Decisions.validation_error!("score legend keys must be Strings") unless index.is_a?(String)

          [index.dup.freeze, Decisions.non_empty_string!(label, path: "score legend labels")]
        end.freeze
      end
    end

    class NoulAnswer
      attr_reader :probability

      def initialize(probability:)
        @probability = Probability.parse(probability, path: "noul probability")
        freeze
      end

      def type
        :noul
      end

      def to_h
        { type: "noul", probability: probability }
      end
    end
  end
end
