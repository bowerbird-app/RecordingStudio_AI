# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIProfilesScreen < RecordingStudioAdmin::Screen
    key "profiles"
    icon :adjustments_horizontal
    title "Profiles"
    subtitle "Generative and decision models each profile tries, in order."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.profile_rows(context)
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :profile, title: "Profile", header_tooltip: "The speed and quality mix."
      column :default_profile,
             title: "Default",
             header_tooltip: "Whether new calls use this profile when none is named.",
             value: ->(row, _context) { row.default_profile ? "Yes" : "No" },
             display: :badge,
             display_options: lambda { |_row, _context, value|
               { text: value, style: value == "Yes" ? :success : :default, size: :sm }
             }
      column :kind,
             title: "Kind",
             header_tooltip: "Whether this model writes replies or answers questions."
      column :position,
             title: "Order",
             header_tooltip: "Where this model sits in the profile's list.",
             value: ->(row, _context) { row.position || "—" }
      column :provider, title: "Provider", header_tooltip: "Who this model belongs to."
      column :model,
             title: "Model",
             header_tooltip: "The model name used in calls. Open it to see that provider's models.",
             value: lambda { |row, context|
               next row.model if row.model == "—" || row.provider == "—"

               ActionController::Base.helpers.link_to(
                 row.model,
                 AdminScreens::RecordingStudioAIWidgets.registered_models_path(context, provider: row.provider),
                 data: { turbo_frame: "_top" },
                 aria: { label: "Registered models for #{row.provider}" }
               )
             }
    end
  end
end
