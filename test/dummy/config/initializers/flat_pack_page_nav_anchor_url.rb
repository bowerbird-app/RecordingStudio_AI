# frozen_string_literal: true

# Recording Studio 4.2 default_layout passes PageNav `anchor_url:`.
# FlatPack 0.1.143 PageNav reads `anchor_href:`. Alias without forking the layout.
# Admin 2.0.1 section views still pass Button `url:`; FlatPack 0.1.143 reads `href:`.
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
