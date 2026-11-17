# frozen_string_literal: true

namespace :recording_studio_ai do
  desc "Print missing Recording Studio AI migrations and exit non-zero when any are missing"
  task check_migrations: :environment do
    result = RecordingStudioAI::MissingMigrations.check
    puts result.message
    abort if result.missing?
  end

  desc "Delete expired retained AI responses"
  task cleanup_responses: :environment do
    puts "Deleted #{RecordingStudioAI::ResponseCleanup.call} expired retained responses"
  end

  desc "Delete canonical AI execution history older than the configured retention period"
  task cleanup_history: :environment do
    result = RecordingStudioAI::HistoryCleanup.call
    puts "Deleted AI history: #{result.to_h.map { |name, count| "#{name}=#{count}" }.join(', ')}"
  end
end