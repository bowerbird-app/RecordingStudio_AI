# frozen_string_literal: true

RecordingStudioApi.configure do |config|
  config.openapi_title = "Dummy host API"
  config.documentation_enabled = false
  config.api_management_authorization_required = false
  config.rate_limit_oauth_enabled = false
  config.rate_limit_api_pre_auth_enabled = false
  config.rate_limit_api_enabled = false
  config.rate_limit_fail_closed = false
  config.api_request_logging_enabled = false

  config.api :operations do |api|
    api.openapi_title = "Admin API"
    api.openapi_description = "Restricted admin API. A public token cannot call it."
    api.api_versions = %w[v1]
    api.default_access = :read_only
    api.api_management_authorization_required = false
    api.documentation_enabled = false
    api.api_request_logging_enabled = false
  end
end

RecordingStudioApi.register_default_resource_actions!(api: :operations)
RecordingStudioApi.register_default_capability_actions!(api: :operations)

RecordingStudioApi.register_recordable_type_api(
  "Workspace",
  api: :operations,
  operations: %i[index show],
  serializer: ->(recordable, **) { { name: recordable.name } },
  output_keys: %i[name]
)
