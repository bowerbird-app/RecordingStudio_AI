# frozen_string_literal: true

# Recording Studio 4.2 applies data-theme="rounded" on <body>. Dummy also stamps
# it on <html> so FlatPack tokens that key off the document element still load,
# without vendoring recording_studio/default_layout.
module DummyHtmlRoundedTheme
  extend ActiveSupport::Concern

  included do
    after_action :apply_dummy_html_rounded_theme
  end

  private

  def apply_dummy_html_rounded_theme
    return unless response.media_type&.include?("html")

    body = response.body.to_s
    return if body.blank?
    return if body.match?(/<html\b[^>]*\bdata-theme=/i)

    response.body = body.sub(/<html\b/i, '<html data-theme="rounded"')
  end
end

Rails.application.config.to_prepare do
  [
    ApplicationController,
    (RecordingStudioAI::Admin::ApplicationController if defined?(RecordingStudioAI::Admin::ApplicationController)),
    (RecordingStudioAdmin::ApplicationController if defined?(RecordingStudioAdmin::ApplicationController))
  ].compact.each do |controller|
    next if controller < DummyHtmlRoundedTheme

    controller.include(DummyHtmlRoundedTheme)
  end
end
