# frozen_string_literal: true

module RecordingStudioAI
  module TerminalImmutability
    extend ActiveSupport::Concern

    included do
      validate :prevent_terminal_mutations, on: :update
    end

    class_methods do
      def terminal_status_column
        :status
      end

      def terminal_statuses
        []
      end

      def immutable_after_terminal_columns
        []
      end
    end

    private

    def prevent_terminal_mutations
      return unless self.class.terminal_statuses.include?(status_in_database.to_s)

      immutable_columns = self.class.immutable_after_terminal_columns + [self.class.terminal_status_column]
      changed_immutable_fields = changes_to_save.keys & immutable_columns.map(&:to_s)
      return if changed_immutable_fields.empty?

      errors.add(
        :base,
        "Cannot modify terminal fields after status is terminal: #{changed_immutable_fields.join(', ')}"
      )
    end
  end
end
