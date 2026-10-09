# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260710000016)
class CreateRecordingStudioApiDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :recording_studio_api_api_daily_metrics, id: :uuid do |t|
      t.date :metric_date, null: false
      t.string :route_name, null: false
      t.string :controller_name
      t.string :action_name
      t.string :request_method, null: false
      t.integer :status_class, null: false
      t.bigint :request_count, null: false, default: 0
      t.bigint :rate_limited_count, null: false, default: 0
      t.bigint :client_error_count, null: false, default: 0
      t.bigint :server_error_count, null: false, default: 0
      t.bigint :duration_count, null: false, default: 0
      t.bigint :duration_sum_ms, null: false, default: 0
      t.integer :duration_max_ms, null: false, default: 0

      t.timestamps
    end

    add_index :recording_studio_api_api_daily_metrics,
              %i[metric_date route_name request_method status_class],
              unique: true,
              name: "index_rs_api_daily_metrics_on_dimensions"
    add_index :recording_studio_api_api_daily_metrics, :metric_date

    create_table :recording_studio_api_api_daily_latency_histogram_buckets, id: :uuid do |t|
      t.date :metric_date, null: false
      t.string :route_name, null: false
      t.string :request_method, null: false
      t.integer :status_class, null: false
      t.integer :upper_bound_ms, null: false
      t.bigint :request_count, null: false, default: 0

      t.timestamps
    end

    add_index :recording_studio_api_api_daily_latency_histogram_buckets,
              %i[metric_date route_name request_method status_class upper_bound_ms],
              unique: true,
              name: "index_rs_api_daily_latency_histogram_on_dimensions"
    add_index :recording_studio_api_api_daily_latency_histogram_buckets, :metric_date
  end
end