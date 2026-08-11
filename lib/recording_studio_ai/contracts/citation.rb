# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class Citation
      attr_reader :title, :url, :positions, :metadata

      def initialize(title:, url:, positions: nil, metadata: {})
        @title = title.to_s
        @url = url.to_s
        @positions = positions
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "citation.metadata")

        validate!
      end

      def to_h
        {
          title: title,
          url: url,
          positions: positions,
          metadata: metadata
        }
      end

      private

      def validate!
        return if url.start_with?("http://", "https://")

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "citation url must start with http:// or https://",
          code: "invalid_request"
        )
      end
    end
  end
end
