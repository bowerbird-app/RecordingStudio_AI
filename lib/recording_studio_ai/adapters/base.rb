# frozen_string_literal: true

module RecordingStudioAI
  module Adapters
    class Base
      def generate(request:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #generate"
      end

      def stream(request:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #stream"
      end

      def submit_batch(request:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #submit_batch"
      end

      def refresh_batch(batch:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #refresh_batch"
      end

      def cancel_batch(batch:, candidate:)
        raise NotImplementedError, "#{self.class} must implement #cancel_batch"
      end
    end
  end
end
