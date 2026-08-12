# frozen_string_literal: true

require "test_helper"

class RecordingStudioAIBatchConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class ConcurrentProvider < RecordingStudioAI::Providers::Base
    attr_reader :entered, :release

    def initialize
      @entered = Queue.new
      @release = Queue.new
    end

    def refresh_batch(batch:, candidate:)
      entered << true
      release.pop
      RecordingStudioAI::Providers::BatchResult.new(
        provider_batch_id: batch.provider_batch_id,
        status: "completed",
        items: [ RecordingStudioAI::Providers::BatchItemResult.new(
          reference: "concurrent-item",
          status: "completed",
          text: "one retained result",
          usage: RecordingStudioAI::Contracts::Usage.new(input_tokens: 2, output_tokens: 3, total_tokens: 5)
        ) ]
      )
    end
  end

  setup do
    cleanup_test_records
    @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    @provider = ConcurrentProvider.new
    configuration = RecordingStudioAI::Configuration.new
    configuration.providers[:concurrent] = @provider
    configuration.authorization_handler = ->(**) { true }
    configuration.retain_responses = true
    RecordingStudioAI.instance_variable_set(:@configuration, configuration)

    @user = User.create!(email: "batch-concurrency-#{SecureRandom.hex(4)}@example.com", password: "password123")
    @workspace = Workspace.create!(name: "Batch concurrency #{SecureRandom.hex(4)}")
    @root = RecordingStudio.root_recording_for(@workspace)
    @batch = RecordingStudioAI::Batch.create!(
      status: "processing",
      provider: "concurrent",
      model: "contract-model",
      provider_batch_id: "concurrent-batch",
      root_recording_id: @root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user",
      item_count: 1,
      metadata: { "_recording_studio_ai" => { "capabilities" => [ "provider_batch" ] } }
    )
    @run = RecordingStudioAI::Run.create!(
      operation: "batch",
      status: "running",
      resolved_provider: "concurrent",
      resolved_model: "contract-model",
      root_recording_id: @root.id,
      initiator_type: "User",
      initiator_id: @user.id,
      initiator_kind: "user",
      started_at: Time.current
    )
    @item = @batch.batch_items.create!(
      run: @run, position: 0, reference: "concurrent-item", status: "processing", started_at: Time.current,
      metadata: {}
    )
  end

  teardown do
    RecordingStudioAI::Response.where(batch_item_id: @item&.id).delete_all
    RecordingStudioAI::BatchItem.where(id: @item&.id).delete_all
    RecordingStudioAI::Run.where(id: @run&.id).delete_all
    RecordingStudioAI::Batch.where(id: @batch&.id).delete_all
    cleanup_test_records
    RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
  end

  test "concurrent terminal refreshes persist one stable outcome" do
    errors = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          RecordingStudioAI.refresh_batch(
            batch_id: @batch.id,
            root_recording: @root,
            initiator: @user
          )
        end
      rescue StandardError => error
        errors << error
      end
    end

    begin
      Timeout.timeout(5) { 2.times { @provider.entered.pop } }
    ensure
      2.times { @provider.release << true }
    end
    threads.each { |thread| assert thread.join(10), "concurrent refresh did not finish" }

    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert_equal "completed", @batch.reload.status
    assert_equal "completed", @item.reload.status
    assert_equal "completed", @run.reload.status
    assert_equal 5, @batch.total_tokens
    assert_equal 1, RecordingStudioAI::Response.where(batch_item_id: @item.id).count
  end

  private

  def cleanup_test_records
    workspace_ids = Workspace.where("name LIKE ?", "Batch concurrency %").pluck(:id)
    recording_ids = RecordingStudio::Recording.where(
      recordable_type: "Workspace", recordable_id: workspace_ids
    ).pluck(:id)
    RecordingStudio::Event.where(recording_id: recording_ids).delete_all
    RecordingStudio::Recording.where(id: recording_ids).delete_all
    Workspace.where(id: workspace_ids).delete_all
    User.where("email LIKE ?", "batch-concurrency-%@example.com").delete_all
  end
end
