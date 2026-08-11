# frozen_string_literal: true

module AdminScreens
  RELOADABLE_CONSTANTS = %i[
    RecordingStudioAISection
    RecordingStudioAIOverviewScreen
  ].freeze

  def self.load!
    RELOADABLE_CONSTANTS.each do |name|
      remove_const(name) if const_defined?(name, false)
    end

    load Rails.root.join("app/admin/recording_studio_ai/section.rb")
    load Rails.root.join("app/admin/recording_studio_ai/overview_screen.rb")
  end
end
