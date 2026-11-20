extends SceneTree
# Run: godot --headless --path . -s tests/test_menu.gd
# Escape opens the pause menu (game paused: the clock stops, the hen doesn't move) and closes it; the
# licences and the key list close first. The info overlay is hidden by default and shown from the menu.
# A key rebound in the menu moves the hen instead of the old one, a key taken by an action leaves the
# one that had it, both choices are saved and loaded again, and "Rétablir par défaut" restores the keys.

const Menu := preload("res://menu.gd")

var w


func _initialize() -> void:
	Menu.path = "user://test_menu.cfg"  # not the player's settings
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Menu.path))
	w = load("res://main.tscn").instantiate()
	root.add_child(w)
	_run()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _tap(code: Key) -> void:
	_key(code, true)
	_key(code, false)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


## Horizontal distance walked along the hen's facing while `code` is held for 15 frames.
func _walk(code: Key) -> float:
	var p = w.player
	var start: Vector3 = p.global_position
	_key(code, true)
	await _frames(15)
	_key(code, false)
	await _frames(5)
	return (p.global_position - start).dot(-p.global_basis.z)


func _keys(action: StringName) -> Array:
	return InputMap.action_get_events(action).map(func(e): return e.physical_keycode)


func _run() -> void:
	await _frames(30)  # landed
	var m = w.menu
	var p = w.player
	assert(not w.hud.visible, "overlay shown by default")
	assert(w.hud.text.contains("Saison") and not w.hud.text.contains("ZQSD"), "key help left in the overlay")

	# Escape: paused menu; nothing moves, not even the clock. Escape again: back to the game.
	_tap(KEY_ESCAPE)
	assert(paused and m.screen.visible and m.main.visible and not m.keys.visible and p.mouse_free)
	var t: float = w.daynight.time
	var pos: Vector3 = p.global_position
	_key(KEY_W, true)
	await _frames(20)
	_key(KEY_W, false)
	assert(w.daynight.time == t, "the clock runs in the pause menu")
	assert(p.global_position == pos, "the hen moves in the pause menu")
	assert(w.player.sfx.music.can_process(), "the music should play on in the pause menu")
	_tap(KEY_ESCAPE)
	assert(not paused and not m.screen.visible)
	await _frames(3)
	assert(w.daynight.time != t, "the clock stays stopped after the menu")

	# The overlay, from the menu.
	_tap(KEY_ESCAPE)
	m.hud_button.pressed.emit()
	assert(w.hud.visible and m.hud_button.text == "Masquer l'overlay")
	# Licences from the menu: Escape closes them, then the menu.
	m.main.get_child(3).pressed.emit()
	assert(m.credits.visible)
	_tap(KEY_ESCAPE)
	assert(not m.credits.visible and m.screen.visible and paused)

	# Keys: forward rebound to I in the list; Escape while a key is awaited cancels.
	m.main.get_child(2).pressed.emit()
	assert(m.keys.visible and not m.main.visible)
	m.key_buttons[&"jump"].pressed.emit()
	assert(m.waiting == &"jump")
	_tap(KEY_ESCAPE)
	assert(m.waiting == &"" and m.keys.visible and _keys(&"jump") == [KEY_SPACE])
	m.key_buttons[&"move_forward"].pressed.emit()
	_tap(KEY_I)
	assert(m.waiting == &"" and _keys(&"move_forward") == [KEY_I])
	assert(m.key_buttons[&"move_forward"].text == "I", m.key_buttons[&"move_forward"].text)
	_tap(KEY_ESCAPE)  # back to the main page
	assert(m.main.visible and m.screen.visible and paused)
	_tap(KEY_ESCAPE)
	assert(not paused)
	var by_w: float = await _walk(KEY_W)
	var by_i: float = await _walk(KEY_I)
	print("forward: %.2f m with W, %.2f m with I" % [by_w, by_i])
	assert(absf(by_w) < 0.1, "W still moves forward after rebinding it to I")
	assert(by_i > 1.0, "I should move forward")

	# A key goes to one action: forward on D, right loses it.
	var d := InputEventKey.new()
	d.physical_keycode = KEY_D
	m.rebind(&"move_forward", d)
	assert(_keys(&"move_forward") == [KEY_D] and _keys(&"move_right").is_empty())
	assert(m.key_buttons[&"move_right"].text == "—")

	# Saved and loaded again (as on the next start).
	InputMap.load_from_project_settings()
	w.hud.visible = false
	m.load_settings()
	assert(w.hud.visible, "overlay choice not reloaded")
	assert(_keys(&"move_forward") == [KEY_D] and _keys(&"move_right").is_empty(), "keys not reloaded")
	assert(_keys(&"jump") == [KEY_SPACE])

	# Rétablir par défaut: project.godot's keys, nothing left in the file but the overlay.
	m.reset_keys()
	assert(_keys(&"move_forward") == [KEY_W] and _keys(&"move_right") == [KEY_D])
	assert(m.key_buttons[&"move_forward"].text == "W")
	var cfg := ConfigFile.new()
	assert(cfg.load(Menu.path) == OK and not cfg.has_section("keys") and cfg.get_value("ui", "hud") == true)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Menu.path))
	print("MENU OK")
	quit()
