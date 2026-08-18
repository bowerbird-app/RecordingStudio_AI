# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    module ApplicationHelper
      def admin_status_style(status)
        case status.to_s
        when "completed" then :success
        when "failed", "cancelled", "expired", "denied", "rejected" then :danger
        when "running", "processing", "submitted" then :info
        when "partially_completed", "awaiting_confirmation" then :warning
        else :default
        end
      end

      def admin_duration(milliseconds)
        milliseconds.nil? ? "Unknown" : "#{number_with_delimiter(milliseconds)} ms"
      end

      def admin_tokens(value)
        value.nil? ? "Unknown" : number_with_delimiter(value)
      end

      def admin_identity(type, id, snapshot = nil)
        snapshot.presence || [type, id].compact.join(" #").presence || "Unknown"
      end

      def admin_json(value)
        JSON.pretty_generate(value || {})
      end

      def admin_code_block(code, title:, language: "json")
        render FlatPack::CodeBlock::Component.new(
          title: title,
          language: language,
          code: code.to_s,
          separated: false
        )
      end
    end
  end
end
