# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    class TypeSafe < Base
      module QuestionEncoder
        module_function

        def call(question_set)
          question_set.each_with_object({}) do |entry, encoded|
            encoded[entry.key.canonical_key] = encode(entry.question)
          end
        end

        def encode(question)
          case question.type
          when :choice then encode_choice(question)
          when :score then encode_score(question)
          when :noul then encode_noul(question)
          else
            raise ArgumentError, "Cannot encode #{question.type} as a TypeSafe question"
          end
        end

        def encode_choice(question)
          criteria = question.criteria.to_h do |criterion|
            [criterion.key.canonical_key, criterion.description]
          end
          { type: "choice", instructions: question.instructions, criteria: criteria }
        end

        def encode_score(question)
          { type: "score", instructions: question.instructions, criteria: question.criteria }
        end

        def encode_noul(question)
          encoded = { type: "noul", instructions: question.instructions }
          return encoded unless question.criteria

          encoded.merge(criteria: { "true" => question.criteria[true], "false" => question.criteria[false] })
        end
      end
    end
  end
end
