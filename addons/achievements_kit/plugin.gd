@tool
extends "res://addons/editor_tool_kit/editor_tool_plugin.gd"

## Achievements Kit editor plugin. In 0.1.0 it mounts nothing (the runtime, schema, codegen and
## Snapser bridge need no editor code); the Achievements dock arrives in 0.2.0. Only this file
## and editor/ depend on editor_tool_kit; runtime/ and codegen/ never do, so exported games and
## headless tools load them on their own.


func _config() -> Dictionary:
	return {}
