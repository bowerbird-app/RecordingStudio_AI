# frozen_string_literal: true

module RecordingStudioAI
  module Capabilities
    ALL = %i[
      generation
      streaming
      structured_output
      image_input
      file_input
      provider_native_web_search
      custom_tools
      provider_batch
      provider_batch_cancellation
    ].freeze

    module_function

    def for_request(request, operation:)
      capabilities = [operation.to_sym]
      capabilities << :structured_output if request[:schema]
      capabilities.concat(attachment_capabilities(request[:attachments]))
      if Array(request[:provider_native_tools]).map(&:to_sym).include?(:web_search)
        capabilities << :provider_native_web_search
      end
      capabilities << :custom_tools if Array(request[:custom_tools]).any?
      capabilities.uniq
    end

    def attachment_capabilities(attachments)
      Array(attachments).filter_map do |attachment|
        type = attachment.respond_to?(:[]) ? (attachment[:type] || attachment["type"]) : nil
        type.to_s == "image" ? :image_input : :file_input
      end
    end

    def for_batch(items, cancellation: false)
      capabilities = items.flat_map { |item| for_request(item, operation: :generation) }
      capabilities << :provider_batch
      capabilities << :provider_batch_cancellation if cancellation
      capabilities.uniq
    end
  end
end
