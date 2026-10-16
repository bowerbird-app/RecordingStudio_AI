# frozen_string_literal: true

require "test_helper"
require "securerandom"

# Opt-in coverage against the real Agents API. Never runs unless
# RECORDING_STUDIO_AI_LIVE_AGENTS=1 was set before the suite loaded, and the
# key was present then. The key is not printed.
class HostedAgentLiveTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  def setup
    super
    @root = Actor.new(create_recording_id)
    @initiator = Actor.new(7)
  end

  def test_live_session_round_trip
    skip "Set RECORDING_STUDIO_AI_LIVE_AGENTS=1 to run the live Agents API test" unless live_key

    configuration = isolate_allow_all_configuration!
    configuration.openai_api_key = live_key
    session = nil
    session = RecordingStudioAI::Agents.create_session(
      instructions: "Reply with the single word pong.",
      model: "gpt-6-astra",
      input: "ping",
      idempotency_key: "live-#{SecureRandom.hex(8)}",
      purpose: "agent_chat",
      root_recording: @root,
      initiator: @initiator
    )

    assert_equal :openai, session.provider
    refute_empty session.provider_session_id
    recovery = RecordingStudioAI::Agents.recover(
      session: session, root_recording: @root, initiator: @initiator
    )
    assert_equal session.provider_session_id, recovery.session.provider_session_id
  ensure
    if session
      RecordingStudioAI::Agents.delete_session(
        session: session, root_recording: @root, initiator: @initiator
      )
    end
  end

  private

  def live_key
    RecordingStudioAI::Test::LIVE_OPENAI_API_KEY
  end
end
