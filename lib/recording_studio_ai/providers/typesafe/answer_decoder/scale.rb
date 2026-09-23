# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    class TypeSafe < Base
      module AnswerDecoder
        module_function

        def scale_score!(score, question, canonical_key)
          RecordingStudioAI::Decisions.finite_number!(score, path: "response answers[#{canonical_key}] score")
          return score if score.between?(0, question.maximum_score)

          invalid!("response answers[#{canonical_key}] score is outside the requested scale")
        end

        # A partial legend is accepted. Every reported index has to sit on the
        # requested scale, and the label has to be the criterion the caller sent.
        def matched_legend!(legend, question, canonical_key)
          invalid!("response answers[#{canonical_key}] legend must be a Hash") unless legend.is_a?(Hash)

          legend.each { |index, label| match_legend_entry!(index, label, question, canonical_key) }
          legend
        end

        def match_legend_entry!(index, label, question, canonical_key)
          unless scale_index?(index, question)
            invalid!("response answers[#{canonical_key}] legend key #{index.inspect} is outside the requested scale")
          end
          return if label == question.criteria[index.to_i]

          invalid!(
            "response answers[#{canonical_key}] legend label for #{index} does not match the requested criterion"
          )
        end

        def scale_probability_keys!(probabilities, question, canonical_key)
          invalid!("response answers[#{canonical_key}] probabilities must be a Hash") unless probabilities.is_a?(Hash)

          probabilities.each_key do |index|
            next if scale_index?(index, question)

            invalid!(
              "response answers[#{canonical_key}] probabilities key #{index.inspect} is outside the requested scale"
            )
          end
          probabilities
        end

        def scale_index?(index, question)
          return false unless index.is_a?(String)

          ordinal = index.to_i
          index == ordinal.to_s && ordinal >= 0 && ordinal < question.criteria.length
        end
      end
    end
  end
end
