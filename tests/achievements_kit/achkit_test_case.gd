extends RefCounted

## Base for achievements_kit test files. A test file is any
## res://tests/achievements_kit/**/test_*.gd that extends this script:
##
##   extends "res://tests/achievements_kit/achkit_test_case.gd"
##   func test_canonical_follows_chains() -> void:
##       check_eq(AchKitSchema.canonical(&"a", {&"a": &"b"}), &"b", "one hop")
##
## Every method named test_* runs once, in declaration order; it may be a coroutine (await
## freely). before_each()/after_each() wrap each test. Nodes added with add_node() are freed
## after each test. Tests never write files and never touch the network.

## The running SceneTree (set by the runner).
var tree: SceneTree
## Failure messages for the current test (the runner reads and clears it).
var failures: PackedStringArray = PackedStringArray()

var _nodes: Array[Node] = []


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func check(cond: bool, label: String) -> void:
	if not cond:
		failures.append(label)


func check_eq(actual: Variant, expected: Variant, label: String) -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: expected %s (%s), got %s (%s)" % [label, var_to_str(expected),
			type_string(typeof(expected)), var_to_str(actual), type_string(typeof(actual))])


## Some entry of `problems` contains `needle`.
func check_problem(problems: PackedStringArray, needle: String, label: String) -> void:
	for p in problems:
		if p.contains(needle):
			return
	failures.append("%s: no problem containing \"%s\" in %s" % [label, needle, var_to_str(problems)])


## Add a node under the tree root; it is freed after the current test.
func add_node(n: Node) -> Node:
	tree.root.add_child(n)
	_nodes.append(n)
	return n


## Let deferred calls (the tracker's post-load pass, the bridge's coalesced post) and short
## coroutines run.
func settle(frames: int = 3) -> void:
	for i in frames:
		await tree.process_frame


## Called by the runner after after_each().
func _free_nodes() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
