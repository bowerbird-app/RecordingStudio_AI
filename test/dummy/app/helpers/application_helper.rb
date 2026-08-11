module ApplicationHelper
	def recording_tree_root_recording
		return current_root_recording if respond_to?(:current_root_recording) && current_root_recording.present?

		if respond_to?(:recording_studio_root_switch_context)
			recording_studio_root_switch_context&.selected_root
		end
	end

	def recording_tree_node
		root = recording_tree_root_recording
		return nil if root.blank?

		recordings = RecordingStudio::Recording
			.where(root_recording_id: root.id, trashed_at: nil)
			.includes(:recordable)
			.order(:created_at)
			.to_a

		recordings_by_id = recordings.index_by(&:id)
		children_by_parent_id = recordings.group_by(&:parent_recording_id)
		access_roles_by_recording_id = recording_tree_access_roles(recordings)

		build_recording_tree_node(
			recording: root,
			children_by_parent_id: children_by_parent_id,
			recordings_by_id: recordings_by_id,
			access_roles_by_recording_id: access_roles_by_recording_id,
			active_recording_id: root.id
		)
	end

	def render_recording_tree_nodes(builder, node)
		builder.node(
			label: node[:label],
			href: node[:href],
			icon: node[:icon],
			expanded: node[:expanded],
			active: node[:active],
			meta: node[:meta]
		) do |child_builder|
			node[:children].each { |child| render_recording_tree_nodes(child_builder, child) }
		end
	end

	private

	def build_recording_tree_node(recording:, children_by_parent_id:, recordings_by_id:, access_roles_by_recording_id:, active_recording_id:)
		role = access_roles_by_recording_id[recording.id]

		{
			label: recording_tree_label(recording),
			href: nil,
			icon: recording_tree_icon(recording),
			expanded: true,
			active: recording.id == active_recording_id,
			meta: "#{recording.recordable_type.to_s.demodulize} · #{recording_tree_access_label(role)}",
			children: Array(children_by_parent_id[recording.id]).filter_map do |child|
				next unless recordings_by_id.key?(child.id)

				build_recording_tree_node(
					recording: child,
					children_by_parent_id: children_by_parent_id,
					recordings_by_id: recordings_by_id,
					access_roles_by_recording_id: access_roles_by_recording_id,
					active_recording_id: active_recording_id
				)
			end
		}
	end

	def recording_tree_access_roles(recordings)
		actor = Current.actor if defined?(Current) && Current.respond_to?(:actor)
		return {} unless actor

		recordings.each_with_object({}) do |recording, result|
			role = RecordingStudioAccessible.role_for(actor: actor, recording: recording)
			result[recording.id] = role
		end
	end

	def recording_tree_access_label(role)
		role.present? ? "#{role} access" : "no access"
	end

	def recording_tree_label(recording)
		recordable = recording.recordable
		return "Root" unless recordable

		if recordable.respond_to?(:name)
			recordable.name.to_s
		elsif recordable.respond_to?(:title)
			recordable.title.to_s
		else
			recordable.class.name.demodulize
		end
	end

	def recording_tree_icon(recording)
		case recording.recordable_type
		when "Workspace"
			:home
		when "Folder"
			:folder
		when "Page"
			"document-text"
		else
			"circle-stack"
		end
	end
end
