# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def attempt_kind_series(relation, date_range:, field: "recording_studio_ai_attempts.created_at", bucket: :day)
      bucket = bucket.to_sym
      buckets = attempt_kind_bucket_keys(date_range, bucket)
      counts = attempt_kind_counts(relation, field, bucket)

      RecordingStudioAI::Attempt::KINDS.values.filter_map do |kind|
        next unless counts.keys.any? { |count_kind, _bucket| count_kind == kind }

        { name: attempt_kind_label(kind), data: attempt_kind_data(kind, buckets, counts, bucket) }
      end
    end

    def attempt_kind_label(kind)
      english = ATTEMPT_KIND_LABELS.fetch(kind.to_s, kind.to_s.humanize)
      Copy.t("admin.attempt_kinds.#{kind}", default: english)
    end

    def attempt_kind_counts(relation, field, bucket)
      relation.reorder(nil).pluck(:kind, Arel.sql(field)).each_with_object(Hash.new(0)) do |row, counts|
        kind, created_at = row
        next if created_at.blank?

        counts[[kind.to_s, attempt_kind_bucket_key(created_at, bucket)]] += 1
      end
    end

    def attempt_kind_data(kind, buckets, counts, bucket)
      buckets.map do |bucket_key|
        { x: attempt_kind_bucket_label(bucket_key, bucket), y: counts.fetch([kind, bucket_key], 0) }
      end
    end

    def attempt_kind_bucket_keys(date_range, bucket)
      return [] unless date_range && date_range.start_date && date_range.end_date

      start_at = attempt_kind_bucket_key(date_range.start_date.beginning_of_day, bucket)
      end_at = attempt_kind_bucket_key(date_range.end_date.end_of_day, bucket)
      Enumerator.produce(start_at) { |value| value + attempt_kind_bucket_step(bucket) }
                .take_while { |value| value <= end_at }
    end

    def attempt_kind_bucket_step(bucket)
      { hour: 1.hour, day: 1.day, week: 1.week, month: 1.month, year: 1.year }.fetch(bucket, 1.day)
    end

    def attempt_kind_bucket_key(value, bucket)
      timestamp = value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)

      case bucket
      when :hour
        timestamp.beginning_of_hour
      when :week
        timestamp.beginning_of_week
      when :month
        timestamp.beginning_of_month
      when :year
        timestamp.beginning_of_year
      else
        timestamp.to_date
      end
    end

    def attempt_kind_bucket_label(value, bucket)
      timestamp = value.respond_to?(:in_time_zone) ? value.in_time_zone : Time.zone.parse(value.to_s)

      case bucket
      when :hour
        timestamp.strftime("%-l%P").strip
      when :week
        Copy.t("common.week_of", date: timestamp.strftime("%b %-d"))
      when :month
        timestamp.strftime("%b")
      when :year
        timestamp.strftime("%Y")
      else
        timestamp.strftime("%b %-d")
      end
    end

    def attempt_error_code_column_visible?(context = admin_context)
      values = Array(context&.filter_value(:status)).map(&:to_s)
      return true if values.include?("failed")

      params = context&.params || {}
      Array(params[:attempt_status] || params["attempt_status"]).map(&:to_s).include?("failed")
    end
  end
end
