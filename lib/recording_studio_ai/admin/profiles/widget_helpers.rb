# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    # Raw English kind tokens for row.kind / filter matching (stable across locales).
    PROFILE_KIND_GENERATIVE = "Generative" unless const_defined?(:PROFILE_KIND_GENERATIVE)
    PROFILE_KIND_DECISION = "Decision" unless const_defined?(:PROFILE_KIND_DECISION)

    def profile_rows(_context = nil)
      default_profile = RecordingStudioAI.configuration.default_profile.to_s

      RecordingStudioAI.configuration.profiles.flat_map do |profile, entries|
        profile_key = profile.to_s
        default = profile_key == default_profile
        list = Array(entries)
        next [ProfileRow.new(profile_key, default, nil, "—", "—", "—")] if list.empty?

        list.each_with_index.map do |entry, index|
          attributes = profile_entry_attributes(entry)
          provider = attributes[:provider].to_s
          model = attributes[:model].to_s
          ProfileRow.new(
            profile_key,
            default,
            index + 1,
            provider.presence || "—",
            model.presence || "—",
            profile_kind_label(provider, model, attributes[:capabilities])
          )
        end
      end
    end

    def profile_kind_label(provider, model, capabilities)
      resolved = profile_entry_capabilities(provider, model, capabilities)
      kinds = []
      kinds << PROFILE_KIND_GENERATIVE if resolved.include?(:generation)
      if resolved.include?(:decision) || resolved.any? { |cap| cap.to_s.start_with?("decision_") }
        kinds << PROFILE_KIND_DECISION
      end
      kinds.join(", ").presence || "—"
    end

    def profile_kind_display(kind_string)
      return Copy.t("common.none") if kind_string.blank? || kind_string == "—"

      kind_string.to_s.split(", ").map { |token| profile_kind_token_label(token) }.join(", ")
    end

    def profile_kind_token_label(token)
      case token.to_s
      when PROFILE_KIND_GENERATIVE
        Copy.t("common.generative")
      when PROFILE_KIND_DECISION
        Copy.t("common.decision")
      else
        token.to_s
      end
    end

    def profile_kind_filter_values
      # Raw tokens so params and profile_row_has_kind? stay locale-stable. Admin
      # select labels humanize these strings (English equals the token).
      [PROFILE_KIND_GENERATIVE, PROFILE_KIND_DECISION]
    end

    def profile_name_filter_values
      RecordingStudioAI.configuration.profiles.keys.map(&:to_s)
    end

    def profile_provider_filter_values
      profile_rows.filter_map { |row| row.provider.to_s unless row.provider == "—" }.uniq
    end

    def profile_model_filter_values
      profile_rows.filter_map { |row| row.model.to_s unless row.model == "—" }.uniq
    end

    def profile_row_has_kind?(row, kind)
      row.kind.to_s.split(", ").include?(kind.to_s)
    end

    def profile_entry_attributes(entry)
      if entry.is_a?(RecordingStudioAI::Candidate)
        return { provider: entry.provider, model: entry.model, capabilities: entry.capabilities }
      end

      entry.to_h.transform_keys(&:to_sym)
    end

    def profile_entry_capabilities(provider, model, capabilities)
      return Array(capabilities).map(&:to_sym) unless capabilities.nil?

      Array(RecordingStudioAI.models.fetch(provider, model)&.capabilities).map(&:to_sym)
    end
  end
end
