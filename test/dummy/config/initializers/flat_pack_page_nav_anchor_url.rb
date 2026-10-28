# frozen_string_literal: true

# Accessible 0.21 still passes Card `style:`. Button `url:` and
# `recording_studio_page_nav` stay for sibling screens. Admin 2.7 sets its own heading.
module DummyFlatPackButtonUrl
  def initialize(url: nil, href: nil, **kwargs)
    super(href: href.presence || url, **kwargs)
  end
end

module DummyFlatPackCardStyle
  STYLE_ARGUMENTS = {
    default: { border: :default, shadow: :none },
    elevated: { border: :default, shadow: :md },
    outlined: { border: :strong, shadow: :none },
    flat: { background: :shaded, border: :none, shadow: :none },
    interactive: { border: :default, shadow: :none, hover: :strong },
    list: { border: :default, shadow: :none, hover: :subtle }
  }.freeze

  def initialize(style: nil, **kwargs)
    if style
      mapped = STYLE_ARGUMENTS.fetch(style.to_sym) do
        raise ArgumentError, "unknown card style: #{style}"
      end
      kwargs = mapped.merge(kwargs)
    end
    super(**kwargs)
  end
end

module DummyRecordingStudioPageNav
  def recording_studio_page_nav(**options)
    arguments = { round: true, style: :default }
    arguments[:anchor_href] = options[:page_nav_anchor_url] if options[:page_nav_anchor_url].present?
    arguments[:anchor_tooltip] = options[:page_nav_anchor_label] if options[:page_nav_anchor_label].present?
    arguments[:back_href] = options[:page_nav_back_url] if options[:page_nav_back_url].present?
    arguments[:back_tooltip] = options[:page_nav_back_label] if options[:page_nav_back_label].present?
    flat_pack_page_nav(**arguments)
  end
end

Rails.application.config.to_prepare do
  [
    [FlatPack::Button::Component, DummyFlatPackButtonUrl],
    [FlatPack::Card::Component, DummyFlatPackCardStyle]
  ].each do |component, legacy|
    next unless component.is_a?(Class)
    next if component < legacy

    component.prepend(legacy)
  end

  if defined?(RecordingStudio::LayoutHelper) &&
      !RecordingStudio::LayoutHelper.ancestors.include?(DummyRecordingStudioPageNav)
    RecordingStudio::LayoutHelper.include(DummyRecordingStudioPageNav)
  end
end
