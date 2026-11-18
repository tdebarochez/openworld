extends PanelContainer
## Credits and licences, toggled with L: the Godot Engine's MIT notice and its third-party components'
## copyrights and licences, as the licence asks of a game shipped without the Godot splash screen. The
## texts come from the engine itself (Engine.get_license_text and friends), so they match the build.

var text := TextEdit.new()  # read-only; draws only the visible lines (a RichTextLabel laid out the whole ~100 k characters: 3 fps)


func _init() -> void:
	visible = false
	set_anchors_and_offsets_preset(PRESET_FULL_RECT, PRESET_MODE_MINSIZE, 60)
	text.editable = false
	text.context_menu_enabled = false
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(text)


func _ready() -> void:
	var out := "OpenWorld — fait avec le moteur Godot (godotengine.org)\nL ou Échap : fermer\n\n"
	out += Engine.get_license_text() + "\n\nComposants tiers du moteur\n\n"
	for c in Engine.get_copyright_info():
		out += c.name + "\n"
		for part in c.parts:
			for who in part.copyright:
				out += "  © " + who + "\n"
			out += "  Licence : " + part.license + "\n"
		out += "\n"
	var licences: Dictionary = Engine.get_license_info()
	for name in licences:
		out += "— " + name + " —\n" + licences[name] + "\n\n"
	text.text = out


func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_L or (visible and e.keycode == KEY_ESCAPE):
		visible = not visible
		# Free the mouse to scroll and select while open; take it back on closing.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if visible else Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
