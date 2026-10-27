# frozen_string_literal: true

# Admin 2.3 and Root Switchable 0.9 still pass keywords Flatpack 0.1.319 removed.
# Translate them in the dummy so those screens keep rendering.
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

module DummyFlatPackPageNavLegacy
  REMOVED = %i[
    show_back right_slot back_icon back_style back_size
    anchor_icon anchor_style anchor_size secondary_anchor_href
  ].freeze

  def initialize(anchor_url: nil, anchor_href: nil, anchor_label: nil, anchor_tooltip: nil,
                 back_url: nil, back_href: nil, back_label: nil, back_tooltip: nil, **kwargs)
    close_href = anchor_href || anchor_url
    close_tooltip = anchor_tooltip || anchor_label
    history_href = back_href || back_url
    history_tooltip = back_tooltip || back_label
    super(**kwargs.except(*REMOVED))
    with_back(href: history_href, tooltip: history_tooltip) if history_href.present? || history_tooltip.present?
    with_close(href: close_href, tooltip: close_tooltip) if close_href.present?
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
    [FlatPack::Card::Component, DummyFlatPackCardStyle],
    [FlatPack::PageNav::Component, DummyFlatPackPageNavLegacy]
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
