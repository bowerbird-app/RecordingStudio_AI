# frozen_string_literal: true

# Snapshot and restore I18n backend state without bare I18n.reload! in teardown.
# Reload rebuilds from load_path and drops any store_translations (or other
# in-memory entries) that test_helper or a sibling test may have installed.
#
# I18n's nested translation hashes use default procs, so Marshal.dump fails.
# We deep-copy into plain hashes/arrays instead.
module I18nBackendIsolation
  module_function

  def snapshot!
    {
      load_path: I18n.load_path.dup,
      available_locales: I18n.available_locales.dup,
      locale: I18n.locale,
      translations: deep_copy(translations_hash)
    }
  end

  def restore!(snapshot)
    return if snapshot.nil?

    I18n.load_path.replace(snapshot.fetch(:load_path))
    I18n.available_locales = snapshot.fetch(:available_locales)
    I18n.locale = snapshot.fetch(:locale)
    write_translations!(deep_copy(snapshot.fetch(:translations)))
  end

  def with_snapshot
    snap = snapshot!
    yield
  ensure
    restore!(snap)
  end

  def translations_hash
    simple_backend.instance_variable_get(:@translations)
  end

  def write_translations!(translations)
    simple_backend.instance_variable_set(:@translations, translations)
  end

  def simple_backend
    backend = I18n.backend
    if backend.respond_to?(:backends)
      backend.backends.find { |candidate| candidate.respond_to?(:store_translations) } || backend.backends.first
    else
      backend
    end
  end

  def deep_copy(value)
    case value
    when Hash
      value.transform_values { |child| deep_copy(child) }
    when Array
      value.map { |child| deep_copy(child) }
    else
      value
    end
  end

  # Remove a dotted key from the loaded backend for one locale (mutates in place).
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def delete_key!(locale, full_key)
    I18n.exists?(full_key, locale)
    parts = full_key.split(".").map(&:to_sym)
    leaf = parts.pop
    translations = translations_hash
    locale_key = locale.to_sym
    translations[locale_key] = translations[locale_key].dup if translations[locale_key]&.frozen?

    node = translations[locale_key]
    parts.each do |part|
      break unless node.is_a?(Hash) && node[part].is_a?(Hash)

      node[part] = node[part].dup if node[part].frozen?
      node = node[part]
    end
    node.delete(leaf) if node.is_a?(Hash)
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
end
