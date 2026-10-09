# frozen_string_literal: true

# This migration comes from recording_studio_api (originally 20260730000018)
class AddApiKeyToRecordingStudioApiRecords < ActiveRecord::Migration[8.1]
  def up
    add_column :recording_studio_api_api_clients, :api_key, :string, null: false, default: "public"
    add_index :recording_studio_api_api_clients, :api_key

    add_column :recording_studio_api_api_request_logs, :api_key, :string, null: false, default: "public"
    add_index :recording_studio_api_api_request_logs, %i[api_key occurred_at], name: "index_rs_api_request_logs_on_api_and_time"

    remove_index :recording_studio_api_api_daily_metrics, name: "index_rs_api_daily_metrics_on_dimensions"
    add_column :recording_studio_api_api_daily_metrics, :api_key, :string, null: false, default: "public"
    add_index :recording_studio_api_api_daily_metrics,
              %i[api_key metric_date route_name request_method status_class],
              unique: true,
              name: "index_rs_api_daily_metrics_on_dimensions"

    remove_index :recording_studio_api_api_daily_latency_histogram_buckets,
                 name: "index_rs_api_daily_latency_histogram_on_dimensions"
    add_column :recording_studio_api_api_daily_latency_histogram_buckets, :api_key, :string, null: false, default: "public"
    add_index :recording_studio_api_api_daily_latency_histogram_buckets,
              %i[api_key metric_date route_name request_method status_class upper_bound_ms],
              unique: true,
              name: "index_rs_api_daily_latency_histogram_on_dimensions"
  end

  def down
    remove_index :recording_studio_api_api_daily_latency_histogram_buckets,
                 name: "index_rs_api_daily_latency_histogram_on_dimensions"
    remove_column :recording_studio_api_api_daily_latency_histogram_buckets, :api_key
    add_index :recording_studio_api_api_daily_latency_histogram_buckets,
              %i[metric_date route_name request_method status_class upper_bound_ms],
              unique: true,
              name: "index_rs_api_daily_latency_histogram_on_dimensions"

    remove_index :recording_studio_api_api_daily_metrics, name: "index_rs_api_daily_metrics_on_dimensions"
    remove_column :recording_studio_api_api_daily_metrics, :api_key
    add_index :recording_studio_api_api_daily_metrics,
              %i[metric_date route_name request_method status_class],
              unique: true,
              name: "index_rs_api_daily_metrics_on_dimensions"

    remove_index :recording_studio_api_api_request_logs, name: "index_rs_api_request_logs_on_api_and_time"
    remove_column :recording_studio_api_api_request_logs, :api_key

    remove_index :recording_studio_api_api_clients, :api_key
    remove_column :recording_studio_api_api_clients, :api_key
  end
end