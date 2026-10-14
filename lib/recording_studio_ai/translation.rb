# frozen_string_literal: true

require "erb"
require "yaml"

module RecordingStudioAI
  # Locale lookups for gem-shipped `recording_studio.ai.*` keys.
  #
  # Fallback order for gem keys missing in the active locale:
  # 1. loaded `:en` (host English overrides included)
  # 2. caller's `default:`
  # 3. gem-shipped `config/locales/en.yml` (eager-loaded, deep-frozen)
  #
  # Non-gem keys, present locale values, Arrays, and lazy keys pass through
  # like `I18n.t`. `_html` gem keys escape interpolation args then mark html_safe,
  # matching view `t`. A missing `_html` key with a non-interpolating caller
  # `default:` stays unsafe like view `t`. An interpolating caller `default:`
  # is stricter: args are escaped and the result is marked html_safe.
  #
  # Partial pluralization data in a non-English locale still raises
  # `I18n::InvalidPluralizationData` (same as `I18n.t`); the English fallback
  # does not fill missing plural keys.
  module Translation
    extend self

    SHIPPED_ENGLISH_MUTEX = Mutex.new
    private_constant :SHIPPED_ENGLISH_MUTEX

    def t(key, **options)
      return nil if key.nil?
      return key.map { |entry| t(entry, **options) } if key.is_a?(Array)
      return ::I18n.t(key, **options) unless gem_key?(key, options[:scope])

      options = escape_html_interpolation(key, options)
      html_safe_translation(key, translate_gem_key(key, options), options)
    end

    # Deep-frozen flat map of gem `config/locales/en.yml` under `recording_studio.ai.*`.
    # Eager-loaded from the engine initializer; reset on Rails code reload.
    # Independent of the I18n backend so a pruned host load path still has text.
    def shipped_english
      return @shipped_english if @shipped_english

      SHIPPED_ENGLISH_MUTEX.synchronize do
        @shipped_english ||= deep_freeze(load_shipped_english)
      end
    end

    def reset_shipped_english!
      SHIPPED_ENGLISH_MUTEX.synchronize { @shipped_english = nil }
    end

    private

    def translate_gem_key(key, options)
      locale = options[:locale] || ::I18n.locale
      scope = options[:scope]
      return ::I18n.t(key, **options) if ::I18n.exists?(key, locale, scope: scope)

      defaults = fallback_defaults(key, scope, options)
      return ::I18n.t(key, **options, default: defaults) if defaults.any?

      ::I18n.t(key, **options)
    end

    def fallback_defaults(key, scope, options)
      caller_defaults = Array(options[:default])
      shipped = shipped_english_value(key, scope)

      if ::I18n.exists?(key, :en, scope: scope)
        english = ::I18n.t(key, **options.except(:default, :raise, :locale), locale: :en)
        return [english, *caller_defaults, *Array(shipped)].compact
      end

      [*caller_defaults, *Array(shipped)].compact
    end

    def gem_key?(key, scope = nil)
      return false unless key.is_a?(String) || key.is_a?(Symbol)

      key_string = key.to_s
      return false if key_string.start_with?(".")
      return recording_studio_ai_name?(Array(scope).join(".")) if scope

      recording_studio_ai_name?(key_string)
    end

    def recording_studio_ai_name?(name)
      name == "recording_studio.ai" || name.start_with?("recording_studio.ai.")
    end

    def shipped_english_value(key, scope = nil)
      full_key = full_gem_key(key, scope)
      full_key && shipped_english[full_key]
    end

    def full_gem_key(key, scope = nil)
      key_string = key.to_s
      return nil if key_string.start_with?(".")

      scope ? "#{Array(scope).join('.')}.#{key_string}" : key_string
    end

    def load_shipped_english
      tree = YAML.safe_load_file(shipped_english_path, aliases: true)
                 .fetch("en")
                 .fetch("recording_studio")
                 .fetch("ai")
      flatten_locale_keys(tree, %w[recording_studio ai])
    rescue Errno::ENOENT
      {}
    end

    def shipped_english_path
      File.expand_path("../../config/locales/en.yml", __dir__)
    end

    def deep_freeze(object)
      case object
      when Hash then object.each_value { |value| deep_freeze(value) }
      when Array then object.each { |value| deep_freeze(value) }
      end
      object.freeze
    end

    def flatten_locale_keys(node, prefix)
      case node
      when Hash
        node.each_with_object({}) do |(key, value), result|
          result.merge!(flatten_locale_keys(value, prefix + [key.to_s]))
        end
      else
        { prefix.join(".") => node }
      end
    end

    def escape_html_interpolation(key, options)
      return options unless html_safe_key?(key)

      options.each_with_object({}) do |(name, value), escaped|
        escaped[name] = escape_interpolation_value(name, value)
      end
    end

    def escape_interpolation_value(name, value)
      return value if i18n_option?(name)
      return value if name == :count && value.is_a?(Numeric)

      ERB::Util.html_escape(value.to_s)
    end

    def i18n_option?(name)
      ::I18n::RESERVED_KEYS.include?(name)
    end

    def html_safe_translation(key, value, options)
      return value unless value.is_a?(String)
      return value unless html_safe_key?(key)
      return value unless value.respond_to?(:html_safe)
      return value if plain_caller_default_result?(key, value, options)

      value.html_safe
    end

    # Non-interpolating caller defaults on a missing `_html` key stay unsafe,
    # matching view `t`. Interpolating defaults that went through arg escaping
    # still get marked html_safe (stricter than view `t`).
    def plain_caller_default_result?(key, value, options)
      default = options[:default]
      return false unless default.is_a?(String)
      return false if default.match?(/%\{/)
      return false unless value == default

      !resolved_translation_present?(key, options)
    end

    def resolved_translation_present?(key, options)
      locale = options[:locale] || ::I18n.locale
      scope = options[:scope]
      ::I18n.exists?(key, locale, scope: scope) ||
        ::I18n.exists?(key, :en, scope: scope) ||
        !shipped_english_value(key, scope).nil?
    end

    def html_safe_key?(key)
      key.to_s.match?(/(?:\b|_)html\z/)
    end
  end

  def self.t(...)
    Translation.t(...)
  end
end
