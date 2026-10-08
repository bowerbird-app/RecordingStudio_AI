# frozen_string_literal: true

# Compatibility aliases for FlatPack 0.1.207 kwargs.
# FlatPack PageNav reads `anchor_href:` / `secondary_anchor_href:`; Button reads `href:`.
# Keep accepting older `anchor_url:` / `back_url:` / `url:` call sites without forking layouts.
module DummyFlatPackPageNavAnchorUrl
  def initialize(anchor_url: nil, back_url: nil, **kwargs)
    kwargs[:anchor_href] = kwargs[:anchor_href].presence || anchor_url
    super(**kwargs)
  end
end

module DummyFlatPackButtonUrl
  def initialize(url: nil, href: nil, **kwargs)
    super(href: href.presence || url, **kwargs)
  end
end

Rails.application.config.to_prepare do
  if defined?(FlatPack::PageNav::Component) &&
      !(FlatPack::PageNav::Component < DummyFlatPackPageNavAnchorUrl)
    FlatPack::PageNav::Component.prepend(DummyFlatPackPageNavAnchorUrl)
  end

  if defined?(FlatPack::Button::Component) &&
      !(FlatPack::Button::Component < DummyFlatPackButtonUrl)
    FlatPack::Button::Component.prepend(DummyFlatPackButtonUrl)
  end
end
