@tool
extends Control

## The "Achievements" bottom-panel dock: a thin view over achievements_editor_service.gd. A
## filterable list of the game's achievements on the left, a form for the selected one on the
## right, and problems, status, Save / Revert / Reveal file below. Every edit goes straight to
## the service (which validates and keeps RENAMED / RETIRED); this file only lays out controls
## and re-renders on the service's `changed` signal. The enforced tool header (title, version,
## reload) is mounted by EditorToolPlugin.
##
## Text fields edit live (the list, problems and preview follow as you type) without rebuilding
## the form, so focus stays put. The id field renames on Enter or when it loses focus.

const Ui := preload("res://addons/editor_tool_kit/editor_tool_ui.gd")
const Pal := preload("res://addons/editor_tool_kit/tool_palette.gd")

const COL_INDEX := 0
const COL_ID := 1
const COL_NAME := 2
const COL_KIND := 3
const COL_TARGET := 4
const COL_FLAGS := 5
const NEW_CATEGORY := "new…"
const NO_CATEGORY := "(none)"

var service: Node   # achievements_editor_service.gd, injected by the EditorToolPlugin base

var _selected: StringName = &""
var _building := false        # repopulating controls: ignore their change signals
var _editing := false         # an edit from the form is in flight: keep the form as is
var _message := ""            # the last action's result, under the counts
var _disk_note := false       # the file changed on disk while there were unsaved edits
var _confirm_action := Callable()
var _dialog_mode := ""        # "add" | "duplicate"

var _setup: Control
var _setup_label: Label
var _main: Control
var _banner: Label
var _filter: LineEdit
var _tree: Tree
var _form: VBoxContainer
var _problems: ItemList
var _status: Label
var _save_btn: Button
var _renames_toggle: Button
var _renames_body: Label
var _confirm: ConfirmationDialog
var _id_dialog: ConfirmationDialog
var _id_dialog_edit: LineEdit
var _id_dialog_kind: OptionButton
var _id_dialog_kind_row: Control
var _file_dialog: Node
# form controls that are updated in place while editing
var _preview: Label
var _hint_edit: LineEdit
var _category_edit: LineEdit


func _ready() -> void:
	custom_minimum_size = Vector2(0, 480)
	if service != null:
		service.reload()
	_build_ui()
	# Method callable (not a lambda): auto-disconnects when the dock frees, so a late signal
	# can't fire into a freed view.
	if service != null:
		service.changed.connect(_on_service_changed)
	_refresh_all()


func _notification(what: int) -> void:
	if what != NOTIFICATION_APPLICATION_FOCUS_IN or service == null or _main == null:
		return
	if not service.is_configured() or not service.disk_changed():
		return
	if service.is_dirty():
		_disk_note = true
		_refresh_banner()
	else:
		service.reload()
		_message = "Reloaded: the definitions file changed on disk."
		_refresh_status()


# ---- public (tests and the Problems list use these) -----------------------------------


func select_id(id: StringName) -> void:
	if service == null or not service.has_id(id):
		id = &""
	_selected = id
	if id != &"" and _filter != null and not service.filter_ids(_filter.text).has(id):
		_filter.text = ""
	_refresh_tree()
	_rebuild_form()


func selected_id() -> StringName:
	return _selected


# ---- layout -----------------------------------------------------------------------


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", Pal.SEP)
	add_child(root)

	# Fresh install: setup instructions instead of the editor.
	var setup := VBoxContainer.new()
	setup.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_setup_label = Ui.status_label(480)
	setup.add_child(_setup_label)
	setup.add_child(Ui.button_bar([Ui.button("Reload", _on_revert_pressed,
		"Read res://achievements_kit.config.json again")]))
	_setup = setup
	root.add_child(_setup)

	var main := VBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 6)
	_main = main
	root.add_child(_main)

	_banner = Ui.status_label()
	_banner.add_theme_color_override("font_color", Pal.USAGE_WARN)
	main.add_child(_banner)

	var split := Ui.split_root()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(split)
	split.add_child(_build_list_pane())
	split.add_child(_build_form_pane())

	_problems = ItemList.new()
	_problems.custom_minimum_size = Vector2(0, 64)
	_problems.auto_height = false
	_problems.item_selected.connect(_on_problem_selected)
	main.add_child(Ui.section("Problems", _problems))

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", Pal.SEP)
	_status = Ui.status_label()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(_status)
	_save_btn = Ui.button("Save", _on_save_pressed, "Validate, then write the definitions file")
	bottom.add_child(_save_btn)
	bottom.add_child(Ui.button("Revert", _on_revert_pressed, "Drop unsaved edits and reload from disk"))
	bottom.add_child(Ui.button("Reveal file", _on_reveal_pressed,
		"Show the definitions file in the FileSystem dock"))
	main.add_child(bottom)

	_renames_toggle = Ui.button("", _on_renames_toggled, "Ids renamed or deleted after they were saved")
	_renames_toggle.flat = true
	_renames_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	main.add_child(_renames_toggle)
	_renames_body = Ui.status_label()
	_renames_body.add_theme_color_override("font_color", Pal.TEXT_DIM)
	_renames_body.visible = false
	main.add_child(_renames_body)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_on_confirmed)
	add_child(_confirm)
	_build_id_dialog()


func _build_list_pane() -> Control:
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(320, 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter by id, name or kind"
	_filter.clear_button_enabled = true
	_filter.text_changed.connect(_on_filter_changed)
	left.add_child(_filter)

	_tree = Tree.new()
	_tree.columns = 6
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 120)
	var titles := ["#", "id", "name", "kind", "target", "flags"]
	for i in titles.size():
		_tree.set_column_title(i, titles[i])
	for i in [COL_INDEX, COL_TARGET, COL_FLAGS]:
		_tree.set_column_expand(i, false)
		_tree.set_column_custom_minimum_width(i, 52)
	_tree.item_selected.connect(_on_tree_selected)
	left.add_child(_tree)

	left.add_child(Ui.button_bar([
		Ui.button("Add", _on_add_pressed, "New achievement"),
		Ui.button("Duplicate", _on_duplicate_pressed, "Copy the selected achievement"),
		Ui.button("Delete", _on_delete_pressed, "Delete the selected achievement"),
		Ui.button("↑", _on_move_pressed.bind(-1), "Move up (display order)"),
		Ui.button("↓", _on_move_pressed.bind(1), "Move down (display order)"),
	]))
	return left


func _build_form_pane() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_stretch_ratio = 1.3
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(360, 0)
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", Pal.SEP)
	scroll.add_child(_form)
	return scroll


func _build_id_dialog() -> void:
	_id_dialog = ConfirmationDialog.new()
	var box := VBoxContainer.new()
	_id_dialog_edit = LineEdit.new()
	_id_dialog_edit.placeholder_text = "lower_snake_case id (a save key; pick it with care)"
	_id_dialog_edit.custom_minimum_size = Vector2(320, 0)
	box.add_child(Ui.form_row("id", _id_dialog_edit))
	_id_dialog_kind = OptionButton.new()
	_id_dialog_kind_row = Ui.form_row("kind", _id_dialog_kind)
	box.add_child(_id_dialog_kind_row)
	_id_dialog.add_child(box)
	_id_dialog.register_text_enter(_id_dialog_edit)   # Enter confirms
	_id_dialog.confirmed.connect(_on_id_dialog_confirmed)
	add_child(_id_dialog)


# ---- refresh ----------------------------------------------------------------------


func _on_service_changed() -> void:
	if _selected != &"" and not service.has_id(_selected):
		_selected = &""
	_disk_note = _disk_note and service.is_dirty()
	_refresh_all(not _editing)


func _refresh_all(rebuild_form := true) -> void:
	if _main == null:
		return
	var configured: bool = service != null and service.is_configured()
	_setup.visible = not configured
	_main.visible = configured
	if not configured:
		_setup_label.text = _setup_text()
		return
	_refresh_banner()
	_refresh_tree()
	_refresh_problems()
	_refresh_status()
	_refresh_renames()
	if rebuild_form:
		_rebuild_form()
	else:
		_refresh_preview()


func _setup_text() -> String:
	var path := "res://achievements_kit.config.json"
	if service != null:
		path = str(service.config_path)
	return ("Achievements Kit is not configured for this project.\n\n"
		+ "Create %s (outside the addon folder, so updates never overwrite it), for example:\n\n" % path
		+ "{\n  \"definitions\": \"res://scripts/config/achievements.gd\",\n"
		+ "  \"kinds\": \"res://scripts/config/achievement_kinds.gd\",\n"
		+ "  \"earned_key_prefix\": \"prog_ach_\",\n  \"progress_key_prefix\": \"prog_achp_\",\n"
		+ "  \"icon_dir\": \"\"\n}\n\n"
		+ "The kinds file is hand-written (const KINDS); the definitions file is generated here and "
		+ "may not exist yet. See addons/achievements_kit/README.md, then press Reload.")


func _refresh_banner() -> void:
	var lines := PackedStringArray()
	if str(service.load_error()) != "":
		lines.append("Could not load: %s. Save is disabled until it loads; fix the file or revert it "
			% service.load_error() + "in version control, then press Revert.")
	if service.schema_newer():
		lines.append("The definitions file was written by a newer achievements_kit (its SCHEMA is "
			+ "newer than %d). Update the addon before editing it." % AchKitSchema.SCHEMA_VERSION)
	if service.file_exists() and str(service.load_error()) == "" and not service.is_canonical_on_disk():
		lines.append("Hand-edited: the file on disk is not what this dock writes. Saving will normalize it.")
	if not service.file_exists() and str(service.load_error()) == "":
		lines.append("No definitions file yet at %s: Save creates it." % service.definitions_path())
	if _disk_note:
		lines.append("The definitions file changed on disk. Save is refused until you Revert "
			+ "(your unsaved edits here are lost).")
	_banner.text = "\n".join(lines)
	_banner.visible = not lines.is_empty()
	_save_btn.disabled = str(service.load_error()) != ""


func _refresh_tree() -> void:
	if _tree == null or service == null:
		return
	_building = true
	_tree.clear()
	var root := _tree.create_item()
	var order: Array = service.ids()
	var flagged := _problem_ids()
	for id: StringName in service.filter_ids(_filter.text):
		var d: Dictionary = service.get_def(id)
		var it := _tree.create_item(root)
		it.set_metadata(0, id)
		it.set_text(COL_INDEX, str(order.find(id) + 1))
		it.set_text(COL_ID, str(id))
		it.set_text(COL_NAME, str(d.get("name", "")))
		var kind := StringName(str(d.get("kind", "")))
		it.set_text(COL_KIND, str(kind))
		it.set_tooltip_text(COL_KIND, service.kind_caption(kind))
		it.set_text(COL_TARGET, str(d.get("target", "")))
		var flags := ""
		if d.get("hidden") == true:
			flags += "H"
		if flagged.has(id):
			flags += "!"
			it.set_custom_color(COL_FLAGS, Pal.ERROR if flagged[id] else Pal.USAGE_WARN)
			it.set_tooltip_text(COL_FLAGS, "\n".join(service.problems_for(id)))
		it.set_text(COL_FLAGS, flags)
		if id == _selected:
			it.select(COL_INDEX)
	_building = false


## id -> true (has an error) / false (warnings only), for every id with a problem.
func _problem_ids() -> Dictionary:
	var out := {}
	for p: String in service.problems():
		var id: StringName = service.problem_id(p)
		if id != &"":
			out[id] = bool(out.get(id, false)) or not AchKitSchema.is_warning(p)
	return out


func _refresh_problems() -> void:
	_problems.clear()
	var problems: PackedStringArray = service.problems()
	for p in problems:
		var i := _problems.add_item(p)
		_problems.set_item_metadata(i, service.problem_id(p))
		_problems.set_item_custom_fg_color(i, Pal.USAGE_WARN if AchKitSchema.is_warning(p) else Pal.ERROR)
	if problems.is_empty():
		var i := _problems.add_item("No problems.")
		_problems.set_item_metadata(i, &"")
		_problems.set_item_selectable(i, false)
		_problems.set_item_custom_fg_color(i, Pal.TEXT_DIM)


func _refresh_status() -> void:
	var st: Dictionary = service.stats()
	var parts := PackedStringArray()
	parts.append("%d achievements" % int(st.total))
	parts.append("%d hidden" % int(st.hidden))
	var per_kind: Dictionary = st.per_kind
	for k: Variant in per_kind:
		parts.append("%s %d" % [str(k) if str(k) != "" else "(no kind)", int(per_kind[k])])
	var text := " · ".join(parts)
	if service.is_dirty():
		text += "   ● unsaved changes"
	if _message != "":
		text += "\n" + _message
	_status.text = text


func _refresh_renames() -> void:
	var renamed: Dictionary = service.model.renamed
	var retired: Array = service.model.retired
	_renames_toggle.text = "%s Renames & retired (%d renamed, %d retired)" % [
		"▾" if _renames_body.visible else "▸", renamed.size(), retired.size()]
	var lines := PackedStringArray()
	var olds: Array = renamed.keys().map(func(k: Variant) -> String: return str(k))
	olds.sort()
	for old: String in olds:
		lines.append("RENAMED  %s -> %s" % [old, str(renamed[StringName(old)])])
	var gone: Array = retired.map(func(r: Variant) -> String: return str(r))
	gone.sort()
	if not gone.is_empty():
		lines.append("RETIRED  " + ", ".join(gone))
	if lines.is_empty():
		lines.append("Nothing renamed or retired. Renaming or deleting an id that is in the saved "
			+ "file records it here, so players keep what they earned.")
	_renames_body.text = "\n".join(lines)


# ---- the form ---------------------------------------------------------------------


func _rebuild_form() -> void:
	if _form == null or service == null:
		return
	_building = true
	for c in _form.get_children():
		_form.remove_child(c)
		c.queue_free()
	_preview = null
	_hint_edit = null
	_category_edit = null
	if _selected == &"" or not service.has_id(_selected):
		var hint := Label.new()
		hint.text = "Select an achievement, or Add one."
		hint.add_theme_color_override("font_color", Pal.TEXT_DIM)
		_form.add_child(hint)
		_building = false
		return
	var d: Dictionary = service.get_def(_selected)
	_form.add_child(Ui.section("Identity", _identity_body(d)))
	_form.add_child(Ui.section("Trigger", _trigger_body(d)))
	_form.add_child(Ui.section("Display", _display_body(d)))
	_preview = Ui.status_label(300)
	_form.add_child(Ui.section("Preview", _preview))
	_refresh_preview()
	_building = false


func _identity_body(d: Dictionary) -> Control:
	var box := VBoxContainer.new()
	var id_edit := LineEdit.new()
	id_edit.text = str(_selected)
	id_edit.tooltip_text = ("The id is a save key. Renaming a saved id records it in RENAMED so "
		+ "players keep what they earned. Enter or leaving the field renames.")
	id_edit.text_submitted.connect(_on_id_committed)
	id_edit.focus_exited.connect(_on_id_focus_exited.bind(id_edit))
	box.add_child(Ui.form_row("id", id_edit, 96))
	var name_edit := LineEdit.new()
	name_edit.text = str(d.get("name", ""))
	name_edit.placeholder_text = "max %d characters" % AchKitSchema.NAME_MAX
	name_edit.text_changed.connect(_on_text_field.bind("name"))
	box.add_child(Ui.form_row("name", name_edit, 96))
	var desc := TextEdit.new()
	desc.text = str(d.get("description", ""))
	desc.placeholder_text = "max %d characters" % AchKitSchema.DESCRIPTION_MAX
	desc.custom_minimum_size = Vector2(0, 64)
	desc.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	desc.text_changed.connect(_on_description_changed.bind(desc))
	box.add_child(Ui.form_row("description", desc, 96))
	return box


func _trigger_body(d: Dictionary) -> Control:
	var box := VBoxContainer.new()
	var kind := StringName(str(d.get("kind", "")))
	var kinds_opt := OptionButton.new()
	for k: StringName in service.kind_names():
		kinds_opt.add_item(service.kind_caption(k))
		var i := kinds_opt.item_count - 1
		kinds_opt.set_item_metadata(i, k)
		kinds_opt.set_item_tooltip(i, str((service.kinds[k] as Dictionary).get("doc", "")))
		if k == kind:
			kinds_opt.select(i)
	if not service.kinds.has(kind):
		kinds_opt.add_item("<unknown: %s>" % kind)
		kinds_opt.set_item_metadata(kinds_opt.item_count - 1, kind)
		kinds_opt.select(kinds_opt.item_count - 1)
	kinds_opt.item_selected.connect(_on_kind_selected.bind(kinds_opt))
	box.add_child(Ui.form_row("kind", kinds_opt, 96))
	var doc := Ui.status_label(240)
	doc.add_theme_color_override("font_color", Pal.TEXT_DIM)
	var kd: Variant = service.kinds.get(kind)
	doc.text = str((kd as Dictionary).get("doc", "")) if typeof(kd) == TYPE_DICTIONARY else (
		"This kind is not in the kinds file. Pick a declared kind, or add it to the kinds file.")
	box.add_child(doc)

	var target := Ui.spin(1, 1000000000, float(int(d.get("target", 1)) if typeof(d.get("target")) == TYPE_INT else 1))
	target.allow_greater = true
	target.value_changed.connect(_on_target_changed)
	box.add_child(Ui.form_row("target", target, 96))

	var declared: Dictionary = service.kind_params(kind)
	var params: Dictionary = d.get("params", {}) if typeof(d.get("params")) == TYPE_DICTIONARY else {}
	for p: Variant in declared:
		var pname := str(p)
		var spec: Dictionary = declared[p] if typeof(declared[p]) == TYPE_DICTIONARY else {}
		var value: Variant = params.get(pname, AchKitSchema.param_default(spec))
		box.add_child(Ui.form_row(pname, _param_control(pname, spec, value), 96))
	if declared.is_empty():
		var none := Label.new()
		none.text = "This kind has no params."
		none.add_theme_color_override("font_color", Pal.TEXT_DIM)
		box.add_child(none)
	return box


func _param_control(pname: String, spec: Dictionary, value: Variant) -> Control:
	match str(spec.get("type", "")):
		"enum":
			var opt := OptionButton.new()
			var values: Array = spec.get("values", []) if typeof(spec.get("values")) == TYPE_ARRAY else []
			for v: Variant in values:
				opt.add_item(str(v) if str(v) != "" else "(any)")
				opt.set_item_metadata(opt.item_count - 1, str(v))
				if str(v) == str(value):
					opt.select(opt.item_count - 1)
			if not values.map(func(x: Variant) -> String: return str(x)).has(str(value)):
				opt.add_item("<invalid: %s>" % str(value))
				opt.set_item_metadata(opt.item_count - 1, str(value))
				opt.select(opt.item_count - 1)
			opt.item_selected.connect(_on_enum_param.bind(pname, opt))
			return opt
		"int":
			var s := Ui.spin(-1000000000, 1000000000, float(value) if typeof(value) in [TYPE_INT, TYPE_FLOAT] else 0.0)
			s.allow_greater = true
			s.allow_lesser = true
			s.value_changed.connect(_on_int_param.bind(pname))
			return s
		"bool":
			var cb := CheckBox.new()
			cb.button_pressed = value == true
			cb.toggled.connect(_on_param_value.bind(pname))
			return cb
	var le := LineEdit.new()
	le.text = str(value)
	le.placeholder_text = "(any)"
	le.text_changed.connect(_on_param_value.bind(pname))
	return le


func _display_body(d: Dictionary) -> Control:
	var box := VBoxContainer.new()
	var hidden_cb := CheckBox.new()
	hidden_cb.text = "Hidden until earned (shows as ???)"
	hidden_cb.button_pressed = d.get("hidden") == true
	hidden_cb.toggled.connect(_on_hidden_toggled)
	box.add_child(Ui.form_row("hidden", hidden_cb, 96))
	_hint_edit = LineEdit.new()
	_hint_edit.text = str(d.get("hint", ""))
	_hint_edit.placeholder_text = "shown while hidden and locked"
	_hint_edit.editable = d.get("hidden") == true
	_hint_edit.text_changed.connect(_on_text_field.bind("hint"))
	box.add_child(Ui.form_row("hint", _hint_edit, 96))

	var icon_row := HBoxContainer.new()
	var icon_edit := LineEdit.new()
	icon_edit.text = str(d.get("icon", ""))
	icon_edit.placeholder_text = "res:// path, or empty"
	icon_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon_edit.text_changed.connect(_on_text_field.bind("icon"))
	icon_row.add_child(icon_edit)
	icon_row.add_child(Ui.button("Browse", _on_browse_pressed.bind(icon_edit)))
	box.add_child(Ui.form_row("icon", icon_row, 96))

	var cat_row := HBoxContainer.new()
	var cat_opt := OptionButton.new()
	var current := str(d.get("category", ""))
	cat_opt.add_item(NO_CATEGORY)
	cat_opt.set_item_metadata(0, "")
	for c: StringName in service.categories():
		cat_opt.add_item(str(c))
		cat_opt.set_item_metadata(cat_opt.item_count - 1, str(c))
		if str(c) == current:
			cat_opt.select(cat_opt.item_count - 1)
	cat_opt.add_item(NEW_CATEGORY)
	cat_opt.set_item_metadata(cat_opt.item_count - 1, NEW_CATEGORY)
	cat_row.add_child(cat_opt)
	_category_edit = LineEdit.new()
	_category_edit.text = current
	_category_edit.placeholder_text = "category"
	_category_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_category_edit.text_submitted.connect(_on_category_committed)
	_category_edit.focus_exited.connect(_on_category_focus_exited)
	cat_row.add_child(_category_edit)
	cat_opt.item_selected.connect(_on_category_selected.bind(cat_opt))
	box.add_child(Ui.form_row("category", cat_row, 96))
	return box


func _refresh_preview() -> void:
	if _preview == null or _selected == &"":
		return
	var row: Dictionary = service.preview_row(_selected)
	if row.is_empty():
		return
	var locked: Dictionary = row.locked
	var earned: Dictionary = row.earned
	var lines := PackedStringArray()
	lines.append("Locked:  %s   %s" % [locked.name, locked.progress])
	if str(locked.description) != "":
		lines.append("    " + str(locked.description))
	if bool(locked.masked) and str(locked.hint) != "":
		lines.append("    hint: " + str(locked.hint))
	lines.append("Earned:  %s" % earned.name)
	if str(earned.description) != "":
		lines.append("    " + str(earned.description))
	lines.append("")
	lines.append("Save keys:  %s (bool) · %s (int)" % [row.earned_key, row.progress_key])
	if service.is_shipped(_selected):
		lines.append("This id is in the saved file: renaming or deleting it is recorded.")
	_preview.text = "\n".join(lines)


# ---- edits from the form ------------------------------------------------------------


func _edit(field: String, value: Variant) -> void:
	if _building or _selected == &"":
		return
	_editing = true
	var r: Dictionary = service.set_field(_selected, field, value)
	_editing = false
	if not r.ok:
		_say(str(r.error))


func _edit_param(pname: String, value: Variant) -> void:
	if _building or _selected == &"":
		return
	_editing = true
	var r: Dictionary = service.set_param(_selected, pname, value)
	_editing = false
	if not r.ok:
		_say(str(r.error))


func _on_text_field(text: String, field: String) -> void:
	_edit(field, text)


func _on_description_changed(edit: TextEdit) -> void:
	_edit("description", edit.text)


func _on_target_changed(value: float) -> void:
	_edit("target", int(value))


func _on_hidden_toggled(on: bool) -> void:
	_edit("hidden", on)
	if _hint_edit != null:
		_hint_edit.editable = on


func _on_kind_selected(index: int, opt: OptionButton) -> void:
	if _building:
		return
	_edit("kind", opt.get_item_metadata(index))
	_rebuild_form.call_deferred()   # the params rows belong to the new kind


func _on_enum_param(index: int, pname: String, opt: OptionButton) -> void:
	_edit_param(pname, opt.get_item_metadata(index))


func _on_int_param(value: float, pname: String) -> void:
	_edit_param(pname, int(value))


func _on_param_value(value: Variant, pname: String) -> void:
	_edit_param(pname, value)


func _on_id_committed(text: String) -> void:
	if _building or _selected == &"":
		return
	var new_id := StringName(text.strip_edges())
	if new_id == _selected:
		return
	var old := _selected
	_selected = new_id   # so the refresh the rename triggers keeps the row selected
	var r: Dictionary = service.rename(old, new_id)
	if not r.ok:
		_selected = old
		_say(str(r.error))
		_rebuild_form.call_deferred()   # put the old id back in the field
		return
	_say("Renamed %s -> %s%s." % [old, new_id,
		" (recorded in RENAMED)" if bool(r.get("recorded", false)) else ""])


func _on_id_focus_exited(edit: LineEdit) -> void:
	if is_instance_valid(edit):
		_on_id_committed(edit.text)


func _on_category_selected(index: int, opt: OptionButton) -> void:
	if _building:
		return
	var v := str(opt.get_item_metadata(index))
	if v == NEW_CATEGORY:
		_category_edit.text = ""
		_category_edit.grab_focus()
		return
	_category_edit.text = v
	_edit("category", v)
	_rebuild_form.call_deferred()


func _on_category_committed(text: String) -> void:
	if _building or _selected == &"":
		return
	if text.strip_edges() == str(service.get_def(_selected).get("category", "")):
		return
	_edit("category", text.strip_edges())
	_rebuild_form.call_deferred()   # the category list may have changed


func _on_category_focus_exited() -> void:
	if _category_edit != null and is_instance_valid(_category_edit):
		_on_category_committed(_category_edit.text)


func _on_browse_pressed(icon_edit: LineEdit) -> void:
	if _file_dialog == null:
		var cls := &"EditorFileDialog" if ClassDB.class_exists(&"EditorFileDialog") else &"FileDialog"
		_file_dialog = ClassDB.instantiate(cls)
		_file_dialog.set("file_mode", FileDialog.FILE_MODE_OPEN_FILE)
		_file_dialog.set("access", FileDialog.ACCESS_RESOURCES)
		_file_dialog.set("filters", PackedStringArray([
			"*.png, *.svg, *.webp, *.jpg, *.jpeg ; Images", "*.tres, *.res ; Resources"]))
		_file_dialog.connect("file_selected", _on_icon_file_selected)
		add_child(_file_dialog)
	_file_dialog.set_meta("icon_edit", icon_edit)
	var current := icon_edit.text.strip_edges()
	_file_dialog.set("current_dir", current.get_base_dir() if current != "" else str(service.icon_dir()))
	if _file_dialog.has_method("popup_file_dialog"):
		_file_dialog.call("popup_file_dialog")
	else:
		_file_dialog.call("popup_centered_ratio", 0.6)


func _on_icon_file_selected(path: String) -> void:
	var edit: Variant = _file_dialog.get_meta("icon_edit", null)
	if edit is LineEdit and is_instance_valid(edit):
		(edit as LineEdit).text = path
	_edit("icon", path)


# ---- list actions -----------------------------------------------------------------


func _on_filter_changed(_text: String) -> void:
	_refresh_tree()


func _on_tree_selected() -> void:
	if _building:
		return
	var it := _tree.get_selected()
	if it == null:
		return
	var id := StringName(str(it.get_metadata(0)))
	if id == _selected:
		return
	_selected = id
	_rebuild_form()


func _on_problem_selected(index: int) -> void:
	var id := StringName(str(_problems.get_item_metadata(index)))
	if id != &"":
		select_id(id)


func _on_add_pressed() -> void:
	_dialog_mode = "add"
	_id_dialog.title = "New achievement"
	_id_dialog_edit.text = ""
	_id_dialog_kind.clear()
	for k: StringName in service.kind_names():
		_id_dialog_kind.add_item(service.kind_caption(k))
		_id_dialog_kind.set_item_metadata(_id_dialog_kind.item_count - 1, k)
	_id_dialog_kind_row.visible = true
	if _id_dialog_kind.item_count == 0:
		_say("The kinds file declares no kinds: add one there first.")
		return
	_id_dialog.popup_centered()
	_id_dialog_edit.grab_focus()


func _on_duplicate_pressed() -> void:
	if _selected == &"":
		_say("Select the achievement to duplicate.")
		return
	_dialog_mode = "duplicate"
	_id_dialog.title = "Duplicate %s" % _selected
	_id_dialog_edit.text = "%s_copy" % _selected
	_id_dialog_kind_row.visible = false
	_id_dialog.popup_centered()
	_id_dialog_edit.grab_focus()
	_id_dialog_edit.select_all()


func _on_id_dialog_confirmed() -> void:
	var id := StringName(_id_dialog_edit.text.strip_edges())
	var r: Dictionary
	if _dialog_mode == "add":
		var idx := _id_dialog_kind.selected
		r = service.add(id, StringName(str(_id_dialog_kind.get_item_metadata(idx))) if idx >= 0 else &"")
	else:
		r = service.duplicate_entry(_selected, id)
	if not r.ok:
		_say(str(r.error))
		return
	_say("%s %s." % ["Added" if _dialog_mode == "add" else "Duplicated as", id])
	select_id(id)


func _on_delete_pressed() -> void:
	if _selected == &"":
		_say("Select the achievement to delete.")
		return
	var id := _selected
	if service.is_shipped(id):
		_ask(("Delete %s?\n\nIt is in the saved file, so its id is RETIRED and can never be reused. "
			+ "Any RENAMED entries pointing at it are retired too.") % id, _do_delete.bind(id))
	else:
		_ask("Delete %s? It was never saved, so nothing is recorded." % id, _do_delete.bind(id))


func _do_delete(id: StringName) -> void:
	var order: Array = service.ids()
	var at := order.find(id)
	var r: Dictionary = service.remove(id)
	if not r.ok:
		_say(str(r.error))
		return
	_say("Deleted %s%s." % [id, " (retired)" if bool(r.get("retired", false)) else ""])
	var rest: Array = service.ids()
	if not rest.is_empty():
		select_id(rest[clampi(at, 0, rest.size() - 1)])


func _on_move_pressed(delta: int) -> void:
	if _selected == &"":
		return
	var r: Dictionary = service.move(_selected, delta)
	if not r.ok:
		_say(str(r.error))


# ---- file actions -----------------------------------------------------------------


func _on_save_pressed() -> void:
	var r: Dictionary = service.save()
	if r.ok:
		_disk_note = false
		_say("Saved %s (%d bytes)." % [r.path, int(r.bytes)])
		_refresh_all()
	else:
		var why := str(r.error)
		if why.contains("changed on disk"):
			_disk_note = true
			_refresh_banner()
		_say("Not saved: " + why.replace("\n", "; "))


func _on_revert_pressed() -> void:
	if service.is_configured() and service.is_dirty():
		_ask("Discard your unsaved edits and reload from disk?", _do_revert)
	else:
		_do_revert()


func _do_revert() -> void:
	_disk_note = false
	var r: Dictionary = service.revert()
	_message = "Reloaded from disk." if r.ok else ""
	_refresh_all()


func _on_reveal_pressed() -> void:
	var path: String = service.definitions_path()
	if not FileAccess.file_exists(path):
		_say("No definitions file yet: Save creates %s." % path)
		return
	if Engine.is_editor_hint() and path.begins_with("res://"):
		EditorInterface.select_file(path)
	else:
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path))


func _on_renames_toggled() -> void:
	_renames_body.visible = not _renames_body.visible
	_refresh_renames()


# ---- helpers ----------------------------------------------------------------------


func _say(msg: String) -> void:
	_message = msg
	if _status != null and service != null and service.is_configured():
		_refresh_status()


func _ask(text: String, action: Callable) -> void:
	_confirm_action = action
	_confirm.dialog_text = text
	_confirm.popup_centered()


func _on_confirmed() -> void:
	var a := _confirm_action
	_confirm_action = Callable()
	if a.is_valid():
		a.call()
