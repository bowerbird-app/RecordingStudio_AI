# frozen_string_literal: true

# Dummy table for an AdminRoot fixture. It is not a configured recordable:
# `root_recordable_types` must stay `["Workspace"]`. Metrics auth uses a
# Workspace named "Admin" as the AdminRoot recording the host resolver returns.
class AdminRoot < ApplicationRecord
end
