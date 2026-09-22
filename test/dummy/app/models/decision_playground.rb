# frozen_string_literal: true

module DecisionPlayground
  PURPOSE = "dummy_decision_playground"
  EMPTY_PROVIDER_MESSAGE = "A decision needs a configured decision provider."
  PROFILES = { "low" => "Low", "medium" => "Medium", "high" => "High" }.freeze
  README_STATE = "ACME Architects unveiled a waterfront library in Portland today. The firm designed the building, published drawings, and will oversee construction through 2028. The article is a substantial feature about the firm's design, not a passing mention."
  QUESTION_KEY = /\A[a-z][a-z0-9_]*\z/
  SEEDED_QUESTIONS = {
    mentions_target: {
      type: :noul,
      instructions: "Does this content substantially mention ACME Architects?",
      criteria: nil
    },
    described: {
      type: :noul,
      instructions: "Is ACME Architects described as the designer of the library?",
      criteria: {
        true => "The firm is described as the designer",
        false => "The firm is not described as the designer"
      }
    },
    coverage_type: {
      type: :choice,
      instructions: "What type of coverage is this?",
      criteria: {
        feature: "A substantial feature about the target",
        mention: "A shorter mention",
        unrelated: "Not meaningfully about the target"
      }
    },
    relevance: {
      type: :score,
      instructions: "How relevant is this content to ACME Architects?",
      criteria: [ "Not relevant", "Weakly relevant", "Clearly relevant", "Primarily about the target" ]
    }
  }.freeze

  QuestionRow = Data.define(:index, :key, :type, :instructions, :criteria_text)

  module CriteriaCodec
    module_function

    def dump(type, criteria)
      case type.to_s
      when "choice" then dump_choice(criteria)
      when "score" then dump_score(criteria)
      when "noul" then dump_noul(criteria)
      else ""
      end
    end

    def load(type, criteria_text)
      case type.to_s
      when "choice" then load_choice(criteria_text)
      when "score" then load_score(criteria_text)
      when "noul" then load_noul(criteria_text)
      end
    end

    def dump_choice(criteria)
      return "" if criteria.blank?

      criteria.map do |key, description|
        description.nil? ? key.to_s : "#{key}: #{description}"
      end.join("\n")
    end

    def dump_score(criteria)
      Array(criteria).join("\n")
    end

    def dump_noul(criteria)
      return "" if criteria.nil?

      "true: #{criteria[true]}\nfalse: #{criteria[false]}"
    end

    def load_choice(criteria_text)
      criteria_text.to_s.each_line.with_object({}) do |line, criteria|
        line = line.strip
        next if line.empty?

        if line.include?(":")
          key, _separator, description = line.partition(":")
          criteria[key.strip] = description.strip
        else
          criteria[line] = nil
        end
      end
    end

    def load_score(criteria_text)
      criteria_text.to_s.each_line.map(&:strip).reject(&:empty?)
    end

    # QuestionSet looks up value[true] and value[false]; JSON and Rails nested params cannot produce those keys.
    def load_noul(criteria_text)
      return nil if criteria_text.to_s.blank?

      criteria_text.to_s.each_line.with_object({}) do |line, criteria|
        line = line.strip
        next if line.empty?

        raw_key, _separator, description = line.partition(":")
        key = case raw_key.strip
        when "true" then true
        when "false" then false
        else raw_key.strip
        end
        criteria[key] = description.strip
      end
    end
  end

  Form = Data.define(:state, :profile, :model_value, :questions) do
    def self.seed
      model = DecisionPlayground.configured_models.first
      new(
        state: README_STATE,
        profile: "medium",
        model_value: model ? "#{model.provider}|#{model.model}" : "",
        questions: SEEDED_QUESTIONS
      )
    end

    def self.parse(params)
      raw = stringify(params)
      questions = raw["questions"]
      unless questions.is_a?(Array) && questions.all? { |row| row.is_a?(Hash) }
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "questions must be an Array of Hashes",
          code: "invalid_request"
        )
      end

      built = {}
      questions.each do |row|
        row = stringify(row)
        key = row["key"].to_s
        instructions = row["instructions"].to_s
        next if key.blank? && instructions.blank?

        question_key = QUESTION_KEY.match?(key) ? key.to_sym : key
        type = row["type"].to_s
        built[question_key] = {
          type: type,
          instructions: instructions,
          criteria: CriteriaCodec.load(type, row["criteria_text"])
        }
      end

      new(
        state: raw["state"].to_s,
        profile: raw["profile"].to_s,
        model_value: raw["model"].to_s,
        questions: built
      )
    end

    def self.stringify(value)
      hash = if value.respond_to?(:to_unsafe_h)
        value.to_unsafe_h
      elsif value.respond_to?(:to_h) && !value.is_a?(Array)
        value.to_h
      else
        value
      end
      hash.is_a?(Hash) ? hash.deep_stringify_keys : hash
    end
    private_class_method :stringify

    def rows
      questions.each_with_index.map do |(key, question), index|
        attributes = question.to_h.transform_keys(&:to_sym)
        QuestionRow.new(
          index: index,
          key: key.to_s,
          type: attributes[:type].to_s,
          instructions: attributes[:instructions].to_s,
          criteria_text: CriteriaCodec.dump(attributes[:type], attributes[:criteria])
        )
      end
    end

    def to_decide_kwargs(root_recording:, initiator:, request_id:)
      kwargs = {
        state: state,
        questions: questions,
        profile: profile.to_sym,
        purpose: PURPOSE,
        root_recording: root_recording,
        initiator: initiator,
        initiator_kind: "user",
        execution_source: "web",
        request_id: request_id,
        metadata: { source: PURPOSE }
      }
      provider, model = model_value.to_s.split("|", 2)
      if provider.present? && model.present?
        kwargs[:provider] = provider.to_sym
        kwargs[:model] = model
      end
      kwargs
    end
  end

  def self.configured_models
    RecordingStudioAI.models.all.select do |definition|
      next false unless definition.operations.include?(:decision)

      provider = RecordingStudioAI.configuration.providers[definition.provider]
      provider.respond_to?(:configured?) && provider.configured?
    end
  end

  def self.model_options
    configured_models.map do |definition|
      {
        value: "#{definition.provider}|#{definition.model}",
        label: "#{definition.provider.to_s.capitalize} · #{definition.display_name}"
      }
    end
  end

  def self.provider_ready?
    configured_models.any?
  end
end
