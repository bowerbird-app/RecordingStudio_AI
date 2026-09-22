# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    class TypeSafe < Base
      # Parses the TypeSafe System One response into typed answers. Every
      # malformed success body raises InvalidResponse so the adapter can return a
      # non-retryable result instead of letting provider JSON escape.
      module AnswerDecoder
        Decoded = Data.define(:served_model, :answers, :usage)

        class InvalidResponse < StandardError; end

        module_function

        def call(body, questions:)
          invalid!("response must be a Hash") unless body.is_a?(Hash)

          Decoded.new(
            served_model: served_model(body),
            answers: answer_set(body["answers"], questions),
            usage: decode_usage(body["usage"])
          )
        rescue RecordingStudioAI::Errors::ContractValidationError => e
          raise InvalidResponse, e.message
        end

        def answer_set(answers, questions)
          RecordingStudioAI::Decisions::AnswerSet.from_canonical(
            question_set: questions,
            answers: decode_answers(answers, questions)
          )
        end

        def served_model(body)
          value = body["model"]
          return nil if value.nil?

          invalid!("response model must be a non-empty String") unless value.is_a?(String) && !value.strip.empty?

          value
        end

        def decode_answers(answers, questions)
          invalid!("response answers must be a Hash") unless answers.is_a?(Hash)

          answers.to_h do |canonical_key, answer|
            entry = questions.fetch_canonical(canonical_key.to_s)
            invalid!("response answers contains unrequested key #{canonical_key}") unless entry

            [entry.key.canonical_key, decode_answer(answer, entry.question, canonical_key)]
          end
        end

        def decode_answer(answer, question, canonical_key)
          invalid!("response answers[#{canonical_key}] must be a Hash") unless answer.is_a?(Hash)
          unless answer["type"].to_s == question.type.to_s
            invalid!("response answers[#{canonical_key}] type does not match the requested #{question.type} question")
          end

          case question.type
          when :choice then decode_choice(answer, question, canonical_key)
          when :score then decode_score(answer, question, canonical_key)
          when :noul then RecordingStudioAI::Decisions::NoulAnswer.new(probability: answer["noul"])
          else invalid!("response answers[#{canonical_key}] type #{question.type} is not a decision type")
          end
        end

        def decode_choice(answer, question, canonical_key)
          choice = public_criterion!(answer["choice"], question, canonical_key)
          probabilities = probability_keys!(answer["probabilities"], question, canonical_key)
          RecordingStudioAI::Decisions::ChoiceAnswer.new(
            choice: choice,
            probabilities: probabilities,
            confidence: answer["confidence"]
          )
        end

        def decode_score(answer, question, canonical_key)
          RecordingStudioAI::Decisions::ScoreAnswer.new(
            score: scale_score!(answer["score"], question, canonical_key),
            legend: matched_legend!(answer["legend"], question, canonical_key),
            probabilities: scale_probability_keys!(answer["probabilities"], question, canonical_key),
            confidence: answer["confidence"]
          )
        end

        def scale_score!(score, question, canonical_key)
          RecordingStudioAI::Decisions.finite_number!(score, path: "response answers[#{canonical_key}] score")
          return score if score.between?(0, question.maximum_score)

          invalid!("response answers[#{canonical_key}] score is outside the requested scale")
        end

        # A partial legend is accepted. Every reported index has to sit on the
        # requested scale, and the label has to be the criterion the caller sent.
        def matched_legend!(legend, question, canonical_key)
          invalid!("response answers[#{canonical_key}] legend must be a Hash") unless legend.is_a?(Hash)

          legend.each do |index, label|
            unless scale_index?(index, question)
              invalid!(
                "response answers[#{canonical_key}] legend key #{index.inspect} is outside the requested scale"
              )
            end
            next if label == question.criteria[index.to_i]

            invalid!(
              "response answers[#{canonical_key}] legend label for #{index} does not match the requested criterion"
            )
          end
          legend
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

        def public_criterion!(value, question, canonical_key)
          public_key = question.public_choice_for(value.to_s)
          if public_key.nil?
            invalid!("response answers[#{canonical_key}] choice #{value.inspect} is not a requested criterion")
          end

          public_key
        end

        def probability_keys!(probabilities, question, canonical_key)
          invalid!("response answers[#{canonical_key}] probabilities must be a Hash") unless probabilities.is_a?(Hash)

          probabilities.transform_keys do |criterion_key|
            public_criterion!(criterion_key, question, canonical_key)
          end
        end

        def decode_usage(usage)
          return nil unless usage.is_a?(Hash)

          input = token_count!(usage["input_tokens"])
          output = token_count!(usage["output_tokens"])
          RecordingStudioAI::Contracts::Usage.new(
            input_tokens: input,
            output_tokens: output,
            total_tokens: input && output ? input + output : nil
          )
        end

        def token_count!(value)
          return nil if value.nil?

          invalid!("response usage tokens must be non-negative Integers") unless value.is_a?(Integer) && value >= 0

          value
        end

        def invalid!(message)
          raise InvalidResponse, message
        end
      end
    end
  end
end
