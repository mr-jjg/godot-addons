@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

## Achievements Kit editor plugin: mounts the "Achievements" bottom-panel dock, where designers
## author the game's generated definitions file. The shared EditorToolPlugin base constructs the
## service and the dock and mounts / tears them down. All logic lives in the headless
## editor/achievements_editor_service.gd; editor/dock.gd is a thin view over it.
##
## Only this file and editor/ depend on editor_tool_kit; runtime/ and codegen/ never do, so
## exported games and headless tools load them on their own. The game's
## res://achievements_kit.config.json says where its files are (see the README).

const ServiceT := preload("res://addons/achievements_kit/editor/achievements_editor_service.gd")
const DockT := preload("res://addons/achievements_kit/editor/dock.gd")


func _config() -> Dictionary:
	return {
		"panel": "Achievements",
		"service": ServiceT,
		"dock": DockT,
		"service_name": "AchievementsEditorService",
		"dock_name": "Achievements",
	}
