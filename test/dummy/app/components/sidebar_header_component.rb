# frozen_string_literal: true

class SidebarHeaderComponent < FlatPack::Sidebar::Header::Component
  def initialize(version: RecordingStudioAI::VERSION, **system_arguments)
    super(**system_arguments)
    @version = version
  end

  private

  def sidebar_version_label
    "v#{@version}"
  end
end
