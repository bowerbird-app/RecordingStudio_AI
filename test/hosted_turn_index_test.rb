# frozen_string_literal: true

require "test_helper"

class HostedTurnIndexTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  def setup
    super
    @root_id = create_recording_id
    @actor = Actor.new(4)
  end

  def test_the_running_session_index_rejects_a_second_row
    create_running("conv_same")

    assert_raises(ActiveRecord::RecordNotUnique) { create_running("conv_same") }
    create_running("conv_other")
    assert_equal 2, RecordingStudioAI::Run.where(operation: "hosted_agent", status: "running").count
  end

  def test_a_second_process_cannot_insert_another_running_hosted_session
    path = File.join(Dir.tmpdir, "rsai-hosted-#{Process.pid}-#{SecureRandom.hex(4)}.sqlite3")
    note = "#{path}.note"
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path)
    bootstrap_host_tables!
    migrate_persistence!
    RecordingStudioAI::Run.reset_column_information
    @root_id = create_recording_id
    create_running("conv_same")
    pid = Process.fork do
      ActiveRecord::Base.connection_handler.clear_all_connections!
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path)
      begin
        create_running("conv_same")
        exit! 0
      rescue ActiveRecord::RecordNotUnique
        exit! 2
      rescue StandardError => e
        File.write(note, "#{e.class}: #{e.message}")
        exit! 1
      end
    end
    _pid, status = Process.wait2(pid)

    assert_equal 2, status.exitstatus, File.exist?(note) ? File.read(note) : "child exited #{status.exitstatus}"
  ensure
    ActiveRecord::Base.connection_handler.clear_all_connections! if path
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(note) if note
  end

  def test_a_lagging_claim_cannot_replace_a_newer_response
    RecordingStudioAI::HostedResponse.record!(
      provider_session_id: "conv_1", response_id: "resp_1", sequence: 2
    )
    assert RecordingStudioAI::HostedResponse.claim!(
      provider_session_id: "conv_1", response_id: "resp_2", previous_response_id: "resp_1", sequence: 4
    )
    refute RecordingStudioAI::HostedResponse.claim!(
      provider_session_id: "conv_1", response_id: "resp_1", previous_response_id: "resp_1", sequence: 9
    )
    assert_equal "resp_2", RecordingStudioAI::HostedResponse.latest_for("conv_1").response_id

    RecordingStudioAI::HostedResponse.advance_cursor!(response_id: "resp_2", sequence: 8, text_emitted: true)
    RecordingStudioAI::HostedResponse.advance_cursor!(response_id: "resp_2", sequence: 3, text_emitted: false)
    row = RecordingStudioAI::HostedResponse.latest_for("conv_1")
    assert_equal 8, row.sequence_number
    assert_equal true, row.text_emitted
  end

  private

  def create_running(session_id)
    RecordingStudioAI::Run.create!(
      operation: "hosted_agent",
      status: "running",
      root_recording_id: @root_id,
      initiator_type: "User",
      initiator_id: @actor.id,
      initiator_kind: "user",
      provider_session_id: session_id,
      started_at: Time.current
    )
  end
end
