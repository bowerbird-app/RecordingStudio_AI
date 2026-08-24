# frozen_string_literal: true

require "csv"
require "json"

module RecordingStudioAI
  module Attachments
    TYPES = %i[image file].freeze
    IMAGE_SIGNATURES = {
      "image/png" => "\x89PNG\r\n\x1A\n".b,
      "image/jpeg" => "\xFF\xD8\xFF".b,
      "image/gif" => "GIF8".b,
      "image/webp" => "RIFF".b
    }.freeze
    EXTENSIONS = {
      "image/png" => %w[.png],
      "image/jpeg" => %w[.jpg .jpeg],
      "image/gif" => %w[.gif],
      "image/webp" => %w[.webp],
      "application/pdf" => %w[.pdf],
      "application/json" => %w[.json],
      "text/plain" => %w[.txt],
      "text/csv" => %w[.csv],
      "text/markdown" => %w[.md .markdown]
    }.freeze

    module_function

    def validate!(attachments, configuration: RecordingStudioAI.configuration)
      values = Array(attachments)
      reject!("attachments must be an Array") unless attachments.is_a?(Array)
      reject!("too many attachments") if values.length > configuration.maximum_attachment_count

      normalized = values.each_with_index.map { |attachment, index| normalize!(attachment, index, configuration) }
      total_bytes = normalized.sum { |attachment| attachment[:byte_size] }
      if total_bytes > configuration.maximum_attachment_total_bytes
        reject!("combined attachment size exceeds the configured limit")
      end
      normalized
    end

    def metadata(attachments)
      values = Array(attachments)
      {
        attachment_count: values.length,
        attachment_total_bytes: values.sum { |attachment| attachment[:byte_size] },
        attachment_content_types: values.map { |attachment| attachment[:content_type] }.uniq
      }
    end

    def normalize!(attachment, index, configuration)
      reject!("attachments[#{index}] must be a Hash") unless attachment.is_a?(Hash)
      type = value(attachment, :type)&.to_sym
      content_type = value(attachment, :content_type)&.to_s
      data = value(attachment, :data)
      filename = value(attachment, :filename)&.to_s

      reject!("attachments[#{index}].type must be image or file") unless TYPES.include?(type)
      reject!("attachments[#{index}].content_type is required") if content_type.nil? || content_type.empty?
      if (type == :image) != content_type.start_with?("image/")
        reject!("attachments[#{index}].type does not match its content type")
      end
      unless configuration.allowed_attachment_content_types.include?(content_type)
        reject!("attachments[#{index}] has a disallowed content type")
      end
      reject!("attachments[#{index}].data must be a non-empty String") unless data.is_a?(String) && !data.empty?
      if data.bytesize > configuration.maximum_attachment_bytes
        reject!("attachments[#{index}] exceeds the configured size limit")
      end
      validate_extension!(filename, content_type, index) if filename && !filename.empty?
      if type == :image
        validate_image!(data, content_type, index)
      else
        validate_file!(data, content_type, index)
      end

      {
        type: type,
        content_type: content_type,
        data: data.b,
        filename: filename,
        byte_size: data.bytesize
      }
    end

    def validate_image!(data, content_type, index)
      signature = IMAGE_SIGNATURES[content_type]
      reject!("attachments[#{index}] has an unsupported image content type") unless signature

      matches = if content_type == "image/webp"
                  data.start_with?(signature) && data.byteslice(8, 4) == "WEBP"
                else
                  data.start_with?(signature)
                end
      reject!("attachments[#{index}] data does not match its declared content type") unless matches
    end

    def validate_extension!(filename, content_type, index)
      allowed = EXTENSIONS.fetch(content_type, [])
      extension = File.extname(filename).downcase
      return if allowed.include?(extension)

      reject!("attachments[#{index}] filename extension does not match its content type")
    end

    def validate_file!(data, content_type, index)
      case content_type
      when "application/pdf"
        reject!(mismatch_message(index)) unless data.start_with?("%PDF-".b)
      when "application/json"
        JSON.parse(data)
      when "text/csv"
        validate_text!(data, index)
        CSV.parse(data)
      when "text/plain", "text/markdown"
        validate_text!(data, index)
      end
    rescue JSON::ParserError, CSV::MalformedCSVError
      reject!(mismatch_message(index))
    end

    def validate_text!(data, index)
      text = data.dup.force_encoding(Encoding::UTF_8)
      reject!(mismatch_message(index)) unless text.valid_encoding? && !text.include?("\0")
    end

    def mismatch_message(index)
      "attachments[#{index}] data does not match its declared content type"
    end

    def value(hash, key)
      hash[key] || hash[key.to_s]
    end

    def reject!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "attachment_validation")
    end
  end
end
