# frozen_string_literal: true

module RecordingStudio
  module LayoutHelper
    # Provide the page-nav API expected by RecordingStudioAdmin views.
    def recording_studio_page_nav(title:, page_nav_anchor_url:, **_options)
      content_for(:page_nav_back_label, title) if title.present?
      content_for(:page_nav_anchor_url, page_nav_anchor_url) if page_nav_anchor_url.present?
      nil
    end

    def recording_studio_page_nav_right(&block)
      content_for(:page_nav_right, &block) if block_given?
      nil
    end

    # RecordingStudioAdmin can render avatar controls in the page nav when this
    # helper exists. The dummy app does not provide a dedicated avatar presenter.
    def recording_studio_accessible_avatars(_access_recording, **_options)
      ActiveSupport::SafeBuffer.new
    end
  end
end
