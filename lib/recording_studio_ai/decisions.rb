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

    def non_empty_string!(value, path:, maximum: MAXIMUM_TEXT_CHARACTERS)
      validation_error!("#{path} must be a non-empty String") unless value.is_a?(String) && !value.strip.empty?
      if value.length > maximum
        validation_error!("#{path} must be at most #{maximum} characters")
      end

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
      return if total <= MAXIMUM_DECISION_CHARACTERS

      validation_error!("decision input must be at most #{MAXIMUM_DECISION_CHARACTERS} characters")
    end

    def text_characters(question)
      case question
      when Choice
        question.instructions.length + question.criteria.sum { |criterion| criterion.description.to_s.length }
      when Score
        question.instructions.length + question.criteria.sum(&:length)
      when Noul
        descriptions = question.criteria ? question.criteria.values : []
        question.instructions.length + descriptions.sum(&:length)
      else
        question.instructions.length
      end
    end
  end
end

require "recording_studio_ai/decisions/state"
require "recording_studio_ai/decisions/questions"
require "recording_studio_ai/decisions/question_set"
require "recording_studio_ai/decisions/answers"
require "recording_studio_ai/decisions/answer_set"
