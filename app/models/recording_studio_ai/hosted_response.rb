# frozen_string_literal: true

require "zlib"

module RecordingStudioAI
  # SQLite has no advisory lock. A row update is the writer lock, and the
  # sqlite3 busy handler waits without holding Ruby's GVL. PRAGMA busy_timeout
  # sleeps inside SQLite and would freeze the thread that owns the lock.
  module SqliteSessionLock
    def prepare_sqlite_wait!
      raw = connection.raw_connection
      raw.busy_handler_timeout = 5_000 if raw.respond_to?(:busy_handler_timeout=)
    end

    def take_sqlite_lock(provider_session_id)
      row = sqlite_lock_row(provider_session_id)
      return unless row

      # Raw SQL keeps lock_version put. update_columns would bump it and make
      # the caller's in-memory run look stale.
      quoted_time = connection.quote(Time.current)
      connection.execute(<<~SQL.squish)
        UPDATE #{connection.quote_table_name(row.class.table_name)}
        SET updated_at = #{quoted_time}
        WHERE id = #{connection.quote(row.id)}
      SQL
    end

    def sqlite_lock_row(provider_session_id)
      session_id = provider_session_id.to_s
      where(provider_session_id: session_id).order(:id).first ||
        RecordingStudioAI::Run.where(provider_session_id: session_id).order(:id).first
    end
    private :prepare_sqlite_wait!, :take_sqlite_lock, :sqlite_lock_row
  end

  # One OpenAI response that belongs to a hosted conversation. Response ids and
  # the stream cursor live here. Conversation metadata keeps the host model and
  # the latest response id only.
  class HostedResponse < ApplicationRecord
    self.table_name = "recording_studio_ai_hosted_turns"

    RUNNING_INDEX = "idx_rsai_runs_one_running_hosted_session"

    class << self
      include SqliteSessionLock

      def record!(provider_session_id:, response_id:, sequence: nil)
        row = find_or_initialize_by(response_id: response_id.to_s)
        row.provider_session_id = provider_session_id.to_s
        assign_sequence(row, sequence)
        row.save!
        row
      end

      # A lagging stream may record only when it still holds the latest id, or
      # when that latest id is the one this stream is replacing.
      def claim!(provider_session_id:, response_id:, previous_response_id:, sequence: nil)
        transaction do
          session_id = provider_session_id.to_s
          response_id = response_id.to_s
          latest = locked_latest(session_id)
          next false if newer_response?(latest, response_id, previous_response_id)

          record!(provider_session_id: session_id, response_id: response_id, sequence: sequence)
          true
        end
      end

      def advance_cursor!(response_id:, sequence:, text_emitted:)
        return 0 if response_id.blank? || sequence.nil?

        where(response_id: response_id.to_s)
          .where("sequence_number IS NULL OR sequence_number <= ?", sequence.to_i)
          .update_all(sequence_number: sequence.to_i, text_emitted: text_emitted, updated_at: Time.current)
      end

      def response_ids_for(provider_session_id)
        where(provider_session_id: provider_session_id.to_s).order(:id).pluck(:response_id)
      end

      def latest_for(provider_session_id)
        where(provider_session_id: provider_session_id.to_s).order(id: :desc).first
      end

      def with_session_lock(provider_session_id)
        with_connection do
          prepare_sqlite_wait! unless postgres?
          transaction do
            take_lock(provider_session_id)
            yield
          end
        end
      end

      private

      def assign_sequence(row, sequence)
        return if sequence.nil?
        return if row.sequence_number && row.sequence_number > sequence.to_i

        row.sequence_number = sequence.to_i
      end

      def newer_response?(latest, response_id, previous_response_id)
        return false if latest.nil? || latest.response_id == response_id

        previous = previous_response_id.to_s
        previous.empty? || latest.response_id != previous
      end

      def locked_latest(session_id)
        scope = where(provider_session_id: session_id).order(id: :desc)
        scope = scope.lock if postgres?
        scope.first
      end

      def take_lock(provider_session_id)
        return take_postgres_lock(provider_session_id) if postgres?

        take_sqlite_lock(provider_session_id)
      end

      def take_postgres_lock(provider_session_id)
        connection.select_value("SELECT pg_advisory_xact_lock(#{lock_key(provider_session_id)})")
        assert_running_index_valid!
      end

      def assert_running_index_valid!
        return if @running_index_valid
        return if running_index_valid?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{RUNNING_INDEX} is not a valid index",
          code: "configuration"
        )
      end

      def running_index_valid?
        valid = connection.select_value(running_index_valid_sql)
        @running_index_valid = valid == true || valid.to_s == "t"
      end

      def running_index_valid_sql
        <<~SQL.squish
          SELECT i.indisvalid
          FROM pg_class c
          JOIN pg_index i ON i.indexrelid = c.oid
          WHERE c.relname = #{connection.quote(RUNNING_INDEX)}
        SQL
      end

      def lock_key(provider_session_id)
        Zlib.crc32(provider_session_id.to_s)
      end

      def postgres?
        connection.adapter_name.match?(/postgre/i)
      end
    end
  end
end
