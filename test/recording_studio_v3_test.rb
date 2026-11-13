# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "test_helper"
require_relative "dummy/config/environment"

require "rails/test_help"
require_relative "dummy/test/support/accessible_test_helpers"

class RecordingStudioV3Test < ActiveSupport::TestCase
  include AccessibleTestHelpers

  test "dummy does not prepend PageNav legacy onto Flatpack PageNav" do
    refute FlatPack::PageNav::Component.ancestors.map(&:name).include?("DummyFlatPackPageNavLegacy")
  end

  test "dummy does not remap Button url onto Flatpack Button" do
    refute FlatPack::Button::Component.ancestors.map(&:name).include?("DummyFlatPackButtonUrl")
    refute defined?(DummyFlatPackButtonUrl)
  end

  test "dummy still maps leftover Card style and PageNav arguments" do
    assert FlatPack::Card::Component.ancestors.map(&:name).include?("DummyFlatPackCardStyle")
    assert RecordingStudio::LayoutHelper.ancestors.map(&:name).include?("DummyRecordingStudioPageNav")
  end

  test "dummy recordable declarations validate and expose v3 introspection" do
    assert RecordingStudio.validate_recordable_declarations!
    assert_equal ["Workspace"], RecordingStudio.root_recordable_types
    assert_equal %w[Workspace Folder], RecordingStudio.allowed_parent_types_for("Folder")
    assert_equal %w[Workspace Folder], RecordingStudio.allowed_parent_types_for(Page)
  end

  test "root recordable creates a root recording" do
    workspace = Workspace.create!(name: unique_name("Root Workspace"))

    root_recording = RecordingStudio.root_recording_for(workspace)

    assert_predicate root_recording, :persisted?
    assert_equal workspace, root_recording.recordable
    assert_nil root_recording.parent_recording_id
    assert_equal root_recording.id, root_recording.root_recording_id
  end

  test "allowed child can be recorded under a workspace root" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Child Workspace")))
    folder = Folder.new(name: unique_name("Allowed Folder"))

    recording = record_child(folder, root_recording, root_recording)

    assert_equal folder, recording.recordable
    assert_equal root_recording, recording.parent_recording
  end

  test "page can be recorded under allowed workspace and folder parents" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Page Workspace")))
    folder_recording = record_child(Folder.new(name: unique_name("Page Folder")), root_recording, root_recording)

    workspace_page_recording = record_child(
      Page.new(title: unique_name("Workspace Page")),
      root_recording,
      root_recording
    )
    folder_page_recording = record_child(Page.new(title: unique_name("Folder Page")), root_recording, folder_recording)

    assert_equal root_recording, workspace_page_recording.parent_recording
    assert_equal folder_recording, folder_page_recording.parent_recording
  end

  test "child recordable cannot be created as a root" do
    folder = Folder.create!(name: unique_name("Root Rejected Folder"))

    assert_raises(RecordingStudio::RootNotAllowed) do
      RecordingStudio.root_recording_for(folder)
    end
  end

  test "parentless child under an existing root is invalid" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Parentless Workspace")))
    folder = Folder.create!(name: unique_name("Parentless Folder"))
    recording = RecordingStudio::Recording.new(root_recording: root_recording, recordable: folder)

    assert_not recording.valid?
    assert_includes recording.errors[:parent_recording_id].join, "cannot be blank"
  end

  test "page cannot be recorded under another page" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Invalid Page Workspace")))
    page_recording = record_child(Page.new(title: unique_name("Parent Page")), root_recording, root_recording)

    error = assert_raises(RecordingStudio::InvalidParent) do
      record_child(Page.new(title: unique_name("Nested Page")), root_recording, page_recording)
    end
    assert_equal "Page cannot be recorded under Page", error.message
  end

  test "AI attribution accepts a root and context from the same recording tree" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("AI Workspace")))
    context_recording = record_child(Folder.new(name: unique_name("AI Folder")), root_recording, root_recording)

    attribution = RecordingStudioAI::Contracts::Attribution.new(
      root_recording: root_recording,
      context_recording: context_recording,
      initiator: User.first || User.create!(email: "ai-#{SecureRandom.hex(4)}@example.test", password: "Password")
    )

    assert_equal root_recording.id, attribution.to_h.fetch(:root_recording_id)
    assert_equal context_recording.id, attribution.to_h.fetch(:context_recording_id)
  end

  test "default attribution check accepts a root uuid and a root recording" do
    configuration = RecordingStudioAI::Configuration.new
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Default Root")))
    context_recording = record_child(Folder.new(name: unique_name("Default Folder")), root_recording, root_recording)
    other_root = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Other Root")))
    other_child = record_child(Folder.new(name: unique_name("Other Folder")), other_root, other_root)
    validator = configuration.attribution_validator
    carried = Struct.new(:root_recording_id).new(root_recording.id)
    stranger = User.create!(email: "stranger-#{SecureRandom.hex(4)}@example.test", password: "Password")

    validator.call(root_recording: root_recording.id, context_recording: nil)
    validator.call(root_recording: carried, context_recording: context_recording)
    validator.call(root_recording: root_recording, context_recording: context_recording)

    [context_recording.id, SecureRandom.uuid, Object.new, context_recording, 12, "12abc", stranger,
     Struct.new(:id).new(root_recording.id)].each do |root|
      error = assert_raises(ArgumentError) do
        validator.call(root_recording: root, context_recording: nil)
      end
      assert_equal "root_recording must be a Recording Studio root", error.message
    end

    error = assert_raises(ArgumentError) do
      validator.call(root_recording: root_recording.id, context_recording: other_child)
    end
    assert_equal "context_recording must belong to root_recording", error.message
  end

  test "a missing root uuid raises instead of keeping the raw value" do
    configuration = RecordingStudioAI.configuration
    previous = configuration.attribution_validator
    configuration.attribution_validator = ->(**) { raise "validator should not run" }
    missing = SecureRandom.uuid
    carried = Struct.new(:root_recording_id).new(missing)
    initiator = User.create!(email: "missing-#{SecureRandom.hex(4)}@example.test", password: "Password")

    [missing, carried].each do |root|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI::Contracts::Attribution.new(root_recording: root, initiator: initiator)
      end
      assert_equal "root_recording must be a Recording Studio root", error.message
    end
  ensure
    configuration.attribution_validator = previous
  end

  test "attribution keeps the loaded root before validation" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Loaded Root")))
    configuration = RecordingStudioAI.configuration
    previous = configuration.attribution_validator
    configuration.attribution_validator = default_attribution_validator(configuration)
    initiator = User.create!(email: "loaded-#{SecureRandom.hex(4)}@example.test", password: "Password")

    attribution = RecordingStudioAI::Contracts::Attribution.new(
      root_recording: root_recording.id, initiator: initiator
    )

    assert_equal root_recording, attribution.root_recording
    assert_equal root_recording.id, attribution.to_h.fetch(:root_recording_id)
  ensure
    configuration.attribution_validator = previous
  end

  test "a host attribution validator still runs on the loaded root" do
    configuration = RecordingStudioAI.configuration
    previous = configuration.attribution_validator
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Host Root")))
    seen = nil
    configuration.attribution_validator = lambda do |root_recording:, context_recording:|
      seen = root_recording
      raise ArgumentError, "host rejected #{root_recording.id}" if context_recording.nil?
    end
    initiator = User.create!(email: "host-#{SecureRandom.hex(4)}@example.test", password: "Password")

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::Attribution.new(root_recording: root_recording.id, initiator: initiator)
    end
    assert_equal root_recording, seen
    assert_equal "host rejected #{root_recording.id}", error.message
  ensure
    configuration.attribution_validator = previous
  end

  test "create session with a root uuid saves that root and passes Accessible" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Session Root")))
    actor = User.create!(email: "member-#{SecureRandom.hex(4)}@example.test", password: "Password123!")
    grant_accessible!(recording: root_recording, actor: actor, role: :edit)
    seen = []
    with_default_attribution_and_accessible(seen) do
      session = RecordingStudioAI::Agents.create_session(
        instructions: "Be brief.",
        input: "hello",
        idempotency_key: "bare-root-#{SecureRandom.hex(4)}",
        purpose: "agent_chat",
        profile: :low,
        root_recording: root_recording.id,
        initiator: actor
      )
      run = RecordingStudioAI::Run.find(session.run_id)

      assert_equal root_recording.id, run.root_recording_id
      assert_equal [root_recording], seen
    end
  end

  test "create session with a root uuid denies an actor without access" do
    root_recording = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Closed Root")))
    actor = User.create!(email: "outsider-#{SecureRandom.hex(4)}@example.test", password: "Password123!")
    seen = []
    runs = RecordingStudioAI::Run.count
    with_default_attribution_and_accessible(seen) do
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI::Agents.create_session(
          instructions: "Be brief.",
          input: "hello",
          idempotency_key: "denied-root-#{SecureRandom.hex(4)}",
          purpose: "agent_chat",
          profile: :low,
          root_recording: root_recording.id,
          initiator: actor
        )
      end

      assert_equal "authorization", error.code
      assert_equal [root_recording], seen
      assert_equal runs, RecordingStudioAI::Run.count
    end
  end

  test "AI attribution rejects a child root and cross-root context" do
    first_root = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("First AI Workspace")))
    second_root = RecordingStudio.root_recording_for(Workspace.create!(name: unique_name("Second AI Workspace")))
    child = record_child(Folder.new(name: unique_name("Cross-root Folder")), second_root, second_root)
    initiator = User.first || User.create!(email: "ai-#{SecureRandom.hex(4)}@example.test", password: "Password")

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::Attribution.new(root_recording: child, initiator: initiator)
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::Attribution.new(
        root_recording: first_root, context_recording: child, initiator: initiator
      )
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::Attribution.new(root_recording: Object.new, initiator: initiator)
    end
  end

  private

  def record_child(recordable, root_recording, parent_recording)
    actor = Current.actor
    unless actor.is_a?(User) && actor.persisted?
      actor = User.first || User.create!(
        email: "writer-#{SecureRandom.hex(4)}@example.test",
        password: "Password"
      )
    end
    previous_actor = Current.actor
    Current.actor = actor
    grant_accessible!(recording: root_recording, actor: actor, role: :edit)

    RecordingStudio.record!(
      action: "created",
      recordable: recordable,
      root_recording: root_recording,
      parent_recording: parent_recording
    ).recording
  ensure
    Current.actor = previous_actor if defined?(previous_actor)
  end

  def unique_name(prefix)
    "#{prefix} #{SecureRandom.hex(4)}"
  end

  def default_attribution_validator(configuration)
    RecordingStudioAI::Configuration.instance_method(:validate_recording_attribution!).bind(configuration)
  end

  def with_default_attribution_and_accessible(seen, &)
    configuration = RecordingStudioAI.configuration
    previous_validator = configuration.attribution_validator
    previous_authorization = configuration.authorization_handler
    previous_client = configuration.openai_client
    previous_provider = configuration.providers[:openai]
    configuration.attribution_validator = default_attribution_validator(configuration)
    configuration.authorization_handler = RecordingStudioAI::AccessibleAuthorization.method(:call)
    configuration.openai_client = Object.new
    configuration.providers[:openai] = BareIdHostedAdapter.new(configuration: configuration)
    watch_accessible(seen, &)
  ensure
    configuration.attribution_validator = previous_validator
    configuration.authorization_handler = previous_authorization
    configuration.openai_client = previous_client
    configuration.providers[:openai] = previous_provider
  end

  def watch_accessible(seen, &)
    original = RecordingStudioAccessible.method(:authorized?)
    RecordingStudioAccessible.define_singleton_method(:authorized?) do |actor:, recording:, role:|
      seen << recording
      original.call(actor: actor, recording: recording, role: role)
    end
    yield
  ensure
    RecordingStudioAccessible.define_singleton_method(:authorized?, original)
  end
end

class BareIdHostedAdapter < RecordingStudioAI::Providers::Base
  provider_key :openai

  def create_hosted_agent_session(model:, **)
    RecordingStudioAI::Providers::HostedSession.new(
      provider_session_id: "sess_bare", status: "in_progress", model: model
    )
  end
end
