# frozen_string_literal: true

module RecordingStudioAI
  # Provider-independent decision vocabulary. Every value object here is frozen
  # and is only ever built from caller input at the public boundary.
  module Decisions
    QUESTION_TYPES = %i[choice score noul].freeze
    MAXIMUM_STATE_CHARACTERS = 60_000
    MAXIMUM_QUESTIONS = 20
    MAXIMUM_TEXT_CHARACTERS = 4_000
    MAXIMUM_DECISION_CHARACTERS = 80_000

    # Reversible question and criterion key. The caller's key is preserved for
    # lookups; the canonical key is what crosses the provider wire.
    Key = Data.define(:public_key, :canonical_key)

    module_function

    def validation_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
    end

    # Caller keys may be Strings or Symbols. The wire key is the String form, so
    # :risk and "risk" would collide and are rejected instead of merged.
    def key_for(value, path:)
      validation_error!("#{path} keys must be a String or Symbol") unless value.is_a?(String) || value.is_a?(Symbol)

      canonical = value.to_s
      validation_error!("#{path} keys must be non-empty") if canonical.strip.empty?

      Key.new(public_key: value.is_a?(String) ? value.dup.freeze : value, canonical_key: canonical.freeze)
    end

    def reject_key_collisions!(keys, path:)
      duplicates = keys.map(&:canonical_key).tally.select { |_key, count| count > 1 }.keys
      return if duplicates.empty?

      validation_error!("#{path} keys collide after normalization: #{duplicates.join(', ')}")
    end

    def maximum_state_characters
      RecordingStudioAI.configuration.maximum_decision_state_characters
    end

    def maximum_questions
      RecordingStudioAI.configuration.maximum_decision_questions
    end

    def maximum_text_characters
      RecordingStudioAI.configuration.maximum_decision_text_characters
    end

    def maximum_decision_characters
      RecordingStudioAI.configuration.maximum_decision_characters
    end

    def non_empty_string!(value, path:, maximum: nil)
      maximum ||= maximum_text_characters
      validation_error!("#{path} must be a non-empty String") unless value.is_a?(String) && !value.strip.empty?
      validation_error!("#{path} must be at most #{maximum} characters") if value.length > maximum

      value.dup.freeze
    end

    def finite_number!(value, path:)
      unless value.is_a?(Numeric) && !value.is_a?(Complex) && value.to_f.finite?
        validation_error!("#{path} must be a finite number")
      end

      value
    end

    # State, instructions, and criteria are capped individually. This is the
    # combined ceiling so a request cannot sit at every individual maximum at once.
    def ensure_within_character_budget!(state, questions)
      total = state.length + questions.sum { |entry| text_characters(entry.question) }
      return if total <= maximum_decision_characters

      validation_error!("decision input must be at most #{maximum_decision_characters} characters")
    end

    def text_characters(question)
      question.instructions.length + criteria_characters(question)
    end

    def criteria_characters(question)
      case question
      when Choice then question.criteria.sum { |criterion| criterion.description.to_s.length }
      when Score then question.criteria.sum(&:length)
      when Noul then noul_criteria_characters(question)
      else 0
      end
    end

    def noul_criteria_characters(question)
      return 0 unless question.criteria

      question.criteria.values.sum(&:length)
    end
  end
end

require "recording_studio_ai/decisions/state"
require "recording_studio_ai/decisions/questions"
require "recording_studio_ai/decisions/question_set"
require "recording_studio_ai/decisions/answers"
require "recording_studio_ai/decisions/answer_set"
