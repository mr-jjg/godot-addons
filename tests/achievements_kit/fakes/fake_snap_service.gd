extends Node

## Stands in for a SnapKitService in AchKitSnapserBridge tests: records track() and
## record_stat() calls; online, booted and offline are settable; finish_boot() emits
## boot_finished like the real startup sequence.

signal boot_finished


class FakeConfig extends RefCounted:
	var offline := false

	func is_offline() -> bool:
		return offline


var config := FakeConfig.new()
var online := true
var booted := true
## [event, props] per track().
var tracked: Array = []
## [key, value] per record_stat().
var stats: Array = []
## What record_stat() answers (plus "value").
var stat_result := {"ok": true, "error": ""}


func track(event: String, props: Dictionary = {}) -> void:
	tracked.append([event, props])


## COROUTINE (one frame of "network" when in the tree).
func record_stat(key: String, value: int) -> Dictionary:
	stats.append([key, value])
	if is_inside_tree():
		await get_tree().process_frame
	var r := stat_result.duplicate()
	r["value"] = value
	return r


func wait_until_ready() -> bool:
	if not booted:
		await boot_finished
	return is_online()


func is_online() -> bool:
	return online and not config.offline


func is_booted() -> bool:
	return booted


func finish_boot() -> void:
	booted = true
	boot_finished.emit()
