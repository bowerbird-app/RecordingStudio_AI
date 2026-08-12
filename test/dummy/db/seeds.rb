# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

find_or_record_child = lambda do |recordable, root_recording, parent_recording|
  RecordingStudio::Recording.find_by(
    root_recording: root_recording,
    parent_recording: parent_recording,
    recordable: recordable,
    trashed_at: nil
  ) || RecordingStudio.record!(
    action: "created",
    recordable: recordable,
    root_recording: root_recording,
    parent_recording: parent_recording
  ).recording
end

# Create the admin user
user = User.find_or_create_by!(email: "admin@admin.com") do |u|
  u.password = "Password"
  u.password_confirmation = "Password"
end

# Create the workspace recordables
workspace = Workspace.find_or_create_by!(name: "Studio Workspace")
accessible_workspace = Workspace.find_or_create_by!(name: "Client Workspace")
private_workspace = Workspace.find_or_create_by!(name: "Private Workspace")
folder = Folder.find_or_create_by!(name: "Product Docs")
page = Page.find_or_create_by!(title: "Getting Started")

previous_actor = Current.actor
Current.actor = user

begin
  # Create the root recording
  root_recording = RecordingStudio.root_recording_for(workspace)
  accessible_root_recording = RecordingStudio.root_recording_for(accessible_workspace)
  private_root_recording = RecordingStudio.root_recording_for(private_workspace)

  folder_recording = find_or_record_child.call(folder, root_recording, root_recording)

  find_or_record_child.call(page, root_recording, folder_recording)

  previous_access_authorizer = RecordingStudioAccessible.configuration.access_management_authorizer
  RecordingStudioAccessible.configuration.access_management_authorizer = ->(**) { true }

  [root_recording, accessible_root_recording, private_root_recording].each do |seed_root|
    grant_result = RecordingStudioAccessible.grant_access(
      recording: seed_root,
      actor: user,
      role: :admin,
      manager_actor: user
    )
    raise("Failed to seed admin access for root #{seed_root.id}: #{grant_result.error}") unless grant_result.success?
  end

  srand(42)

  seed_roots = [root_recording, accessible_root_recording, private_root_recording]
  providers = {
    "openai" => %w[gpt-4o gpt-4.1-mini gpt-5-mini],
    "anthropic" => %w[claude-3-5-sonnet claude-opus-4],
    "google" => %w[gemini-2.0-flash gemini-2.5-pro]
  }
  tool_keys = [
    "web.search",
    "workspace.lookup",
    "recording.fetch",
    "summarize.recordings",
    "attachments.scan"
  ]

  run_status_for = lambda do
    roll = rand
    return "completed" if roll < 0.81
    return "failed" if roll < 0.94

    "cancelled"
  end

  thirty_days_ago = 29.days.ago.to_date

  (thirty_days_ago..Date.current).each do |day|
    rand(5..12).times do |index|
      request_id = "seed-rsai-run-#{day.iso8601}-#{index}"
      next if RecordingStudioAI::Run.exists?(request_id: request_id)

      provider = providers.keys.sample
      model = providers.fetch(provider).sample
      status = run_status_for.call
      operation = rand < 0.82 ? "generation" : "stream"
      started_at = day.beginning_of_day + rand(0..86_399).seconds
      latency_ms = rand(120..6_200)
      completed_at = started_at + (latency_ms / 1000.0)
      input_tokens = rand(120..2_800)
      output_tokens = rand(80..2_600)
      total_tokens = input_tokens + output_tokens
      estimated_cost_per_token =
        if model.match?(/gpt-5|opus|2\.5-pro/i)
          rand(4.0..8.0)
        else
          rand(1.2..3.8)
        end
      cost_amount_microunits = (total_tokens * estimated_cost_per_token).to_i
      tool_invocation_count = rand < 0.62 ? rand(0..3) : 0
      retry_count = status == "failed" ? rand(0..2) : rand(0..1)
      fallback_count = status == "failed" ? rand(0..1) : 0
      attempt_count = [1 + retry_count + fallback_count, 1].max
      failed_error = ["provider", "timeout", "rate_limit", "tool_error"].sample
      web_search_requested = rand < 0.35
      web_search_used = web_search_requested && rand < 0.8

      run = RecordingStudioAI::Run.create!(
        operation: operation,
        status: status,
        request_id: request_id,
        profile_key: ["default", "balanced", "fast"].sample,
        requested_provider: provider,
        resolved_provider: provider,
        resolved_model: model,
        root_recording_id: seed_roots.sample.id,
        context_recording_id: nil,
        initiator_type: "User",
        initiator_id: user.id,
        initiator_kind: "human",
        initiator_snapshot: { email: user.email },
        executor_type: "User",
        executor_id: user.id,
        executor_kind: "manual",
        executor_snapshot: { email: user.email },
        execution_source: ["sync", "job"].sample,
        started_at: started_at,
        completed_at: completed_at,
        latency_ms: latency_ms,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        cost_amount_microunits: cost_amount_microunits,
        cost_currency: "USD",
        cost_estimated: true,
        attempt_count: attempt_count,
        retry_count: retry_count,
        fallback_count: fallback_count,
        custom_tool_invocation_count: tool_invocation_count,
        citation_count: web_search_used ? rand(1..6) : 0,
        web_search_requested: web_search_requested,
        web_search_used: web_search_used,
        error_category: status == "failed" ? failed_error : nil,
        error_code: status == "failed" ? "seed_failure" : nil,
        error_message: status == "failed" ? "Simulated seeded failure" : nil,
        purpose: ["assistant", "draft", "analysis"].sample,
        created_at: started_at,
        updated_at: completed_at
      )

      attempt_count.times do |sequence|
        attempt_kind =
          if sequence.zero?
            "primary"
          elsif sequence <= retry_count
            "retry"
          else
            "fallback"
          end

        attempt_started_at = started_at + (sequence * rand(5..35)).seconds
        attempt_latency = [latency_ms - (sequence * rand(10..60)), 60].max
        attempt_completed_at = attempt_started_at + (attempt_latency / 1000.0)
        is_last_attempt = sequence == attempt_count - 1
        attempt_status = is_last_attempt ? status : "failed"

        attempt = RecordingStudioAI::Attempt.create!(
          run: run,
          sequence: sequence + 1,
          kind: attempt_kind,
          status: attempt_status,
          profile_key: run.profile_key,
          provider: provider,
          model: model,
          provider_request_id: "seed-attempt-#{run.id}-#{sequence + 1}",
          streaming: operation == "stream",
          started_at: attempt_started_at,
          completed_at: attempt_completed_at,
          latency_ms: attempt_latency,
          input_tokens: [input_tokens / attempt_count, 1].max,
          output_tokens: [output_tokens / attempt_count, 1].max,
          total_tokens: [total_tokens / attempt_count, 1].max,
          cost_amount_microunits: [cost_amount_microunits / attempt_count, 1].max,
          cost_currency: "USD",
          cost_estimated: true,
          cost_source: "estimate",
          finish_reason: attempt_status == "completed" ? "stop" : "error",
          retryable: attempt_status == "failed",
          web_search_requested: web_search_requested,
          web_search_used: web_search_used,
          citation_count: web_search_used ? rand(0..2) : 0,
          error_category: attempt_status == "failed" ? failed_error : nil,
          error_code: attempt_status == "failed" ? "attempt_failed" : nil,
          error_message: attempt_status == "failed" ? "Simulated attempt failure" : nil,
          created_at: attempt_started_at,
          updated_at: attempt_completed_at
        )

        next unless sequence.zero?
        next if tool_invocation_count.zero?

        tool_invocation_count.times do |tool_index|
          tool_status = rand < 0.84 ? "completed" : ["failed", "denied", "rejected"].sample
          tool_started_at = attempt_started_at + rand(1..30).seconds
          tool_latency = rand(40..1_900)
          tool_completed_at = tool_started_at + (tool_latency / 1000.0)
          confirmation_required = rand < 0.3
          confirmation_status = confirmation_required ? %w[pending confirmed rejected].sample : "not_required"

          confirmed_at = confirmation_status == "confirmed" ? (tool_started_at + rand(1..10).seconds) : nil
          confirmed_by_type = confirmation_status == "confirmed" ? "User" : nil
          confirmed_by_id = confirmation_status == "confirmed" ? user.id : nil

          RecordingStudioAI::CustomToolInvocation.create!(
            run: run,
            requested_by_attempt: attempt,
            continued_by_attempt: nil,
            tool_key: tool_keys.sample,
            tool_version: rand(1..3),
            tool_name_snapshot: "Seeded Tool #{tool_index + 1}",
            status: tool_status,
            provider_tool_call_id: "tool-#{run.id}-#{sequence + 1}-#{tool_index + 1}",
            read_only: rand < 0.65,
            destructive: rand < 0.08,
            requires_confirmation: confirmation_required,
            idempotent: rand < 0.85,
            cost_category: %w[negligible low medium high].sample,
            latency_category: tool_latency < 250 ? "instant" : (tool_latency < 900 ? "fast" : "slow"),
            confirmation_status: confirmation_status,
            confirmed_at: confirmed_at,
            confirmed_by_type: confirmed_by_type,
            confirmed_by_id: confirmed_by_id,
            arguments_digest: "seed-args-#{run.id}-#{tool_index + 1}",
            arguments_summary: "Seeded invocation arguments",
            result_digest: "seed-result-#{run.id}-#{tool_index + 1}",
            result_summary: tool_status == "completed" ? "Seeded successful result" : "Seeded failed result",
            started_at: tool_started_at,
            completed_at: tool_completed_at,
            latency_ms: tool_latency,
            error_category: tool_status == "completed" ? nil : "tool_failure",
            error_code: tool_status == "completed" ? nil : "seeded_tool_error",
            error_message: tool_status == "completed" ? nil : "Simulated tool call failure",
            created_at: tool_started_at,
            updated_at: tool_completed_at
          )
        end
      end
    end
  end

  warning_seed_run = lambda do |request_id:, root_id:, started_at:, status:, provider:, model:, latency_ms:, total_tokens:|
    input_tokens = [((total_tokens * 0.55).to_i), 1].max
    output_tokens = [total_tokens - input_tokens, 1].max
    completed_at = started_at + (latency_ms / 1000.0)
    cost_per_token = model.match?(/gpt-5|opus|2\.5-pro/i) ? 6.5 : 2.2

    run = RecordingStudioAI::Run.find_or_initialize_by(request_id: request_id, created_at: started_at)
    return run if run.persisted?

    run.assign_attributes(
      operation: "generation",
      status: status,
      request_id: request_id,
      profile_key: "default",
      requested_provider: provider,
      resolved_provider: provider,
      resolved_model: model,
      root_recording_id: root_id,
      context_recording_id: nil,
      initiator_type: "User",
      initiator_id: user.id,
      initiator_kind: "human",
      initiator_snapshot: { email: user.email },
      executor_type: "User",
      executor_id: user.id,
      executor_kind: "manual",
      executor_snapshot: { email: user.email },
      execution_source: "sync",
      started_at: started_at,
      completed_at: completed_at,
      latency_ms: latency_ms,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      cost_amount_microunits: (total_tokens * cost_per_token).to_i,
      cost_currency: "USD",
      cost_estimated: true,
      attempt_count: 1,
      retry_count: 0,
      fallback_count: 0,
      custom_tool_invocation_count: 0,
      citation_count: 0,
      web_search_requested: false,
      web_search_used: false,
      error_category: status == "failed" ? "provider" : nil,
      error_code: status == "failed" ? "warning_seed_failure" : nil,
      error_message: status == "failed" ? "Synthetic failure for warning widget seed" : nil,
      purpose: "analysis",
      created_at: started_at
    )
    run.updated_at = completed_at
    run.save!
  end

  # Dedicated warning seed set so warning widget states are easy to preview.
  baseline_days = [8, 7, 6, 5, 4, 3, 2]
  seed_roots.each_with_index do |seed_root, root_index|
    baseline_days.each_with_index do |days_ago, index|
      started_at = days_ago.days.ago.beginning_of_day + (10 + index).hours
      warning_seed_run.call(
        request_id: "seed-rsai-warning-baseline-#{seed_root.id}-#{days_ago}",
        root_id: seed_root.id,
        started_at: started_at,
        status: "completed",
        provider: "openai",
        model: "gpt-4.1-mini",
        latency_ms: 700 + (index * 25),
        total_tokens: 850 + (index * 30)
      )
    end

    # Force all records into the previous 24h window so warning thresholds trigger reliably.
    24.times do |index|
      started_at = Time.current - (index * 10).minutes
      warning_seed_run.call(
        request_id: "seed-rsai-warning-preview-v3-#{seed_root.id}-#{index}",
        root_id: seed_root.id,
        started_at: started_at,
        status: "failed",
        provider: "openai",
        model: index < 12 ? "gpt-5-mini" : "gpt-4o",
        latency_ms: 900 + (index * 40),
        total_tokens: 1_200 + (index * 55)
      )
    end
  end

  RecordingStudioAccessible.configuration.access_management_authorizer = previous_access_authorizer
ensure
  RecordingStudioAccessible.configuration.access_management_authorizer = previous_access_authorizer if defined?(previous_access_authorizer)
  Current.actor = previous_actor
end

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{workspace.name}' with root recording ##{root_recording.id}"
puts "Seeded: Workspace '#{accessible_workspace.name}' with root recording ##{accessible_root_recording.id}"
puts "Seeded: Workspace '#{private_workspace.name}' with root recording ##{private_root_recording.id}"
puts "Seeded: Folder '#{folder.name}' and page '#{page.title}'"
puts "Seeded: Admin access granted for #{user.email} on seeded root recordings"
