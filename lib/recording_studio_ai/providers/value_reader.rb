# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    module ValueReader
      private

      def read_value(object, *keys)
        return nil if object.nil?

        keys.each do |key|
          if object.is_a?(Hash)
            return object[key] if object.key?(key)
            return object[key.to_s] if object.key?(key.to_s)
            return object[key.to_sym] if object.key?(key.to_sym)
          elsif object.respond_to?(key)
            return object.public_send(key)
          end
        end
        nil
      end
    end
  end
end
