extends CanvasLayer
## Pause menu, opened and closed with Escape; the game is paused while it is open. In a browser Escape
## leaves the pointer lock and may never reach the game, so the menu also opens when the mouse goes
## from captured to free without the game asking. Rebinds the keys (InputMap actions declared in
## project.godot), shows the licences (credits.gd) and shows or hides the info overlay (world.hud);
## the choices are saved in `path` and loaded at start.

const ACTIONS := [  # [action, label], in the order listed
	[&"move_forward", "Avancer"], [&"move_back", "Reculer"], [&"move_left", "Aller à gauche"],
	[&"move_right", "Aller à droite"], [&"jump", "Sauter, battre des ailes, remonter"], [&"sprint", "Courir"],
	[&"camera", "Changer de vue"], [&"map", "Carte"], [&"season_1", "Été"], [&"season_2", "Automne"],
	[&"season_3", "Hiver"], [&"season_4", "Printemps"], [&"time_forward", "Avancer l'heure"],
	[&"time_back", "Reculer l'heure"], [&"density", "Objets (Maj : moins)"],
	[&"view_distance", "Portée de vue (Maj : moins)"], [&"weather", "Météo (Maj : précédente)"],
	[&"licences", "Licences"]]
const KEY_NAMES := {"Space": "Espace", "Shift": "Maj", "Plus": "+", "Equal": "=", "Minus": "-",
	"Kp Add": "+ (pavé num.)", "Kp Subtract": "- (pavé num.)", "Enter": "Entrée"}
const CREAM := Color(0.949, 0.914, 0.855)  # the loading veil's

static var path := "user://settings.cfg"  # tests point it elsewhere

var world  # world.gd
var cfg := ConfigFile.new()  # saved settings: [keys] action = events (only the rebound ones), [ui] hud
var screen := Control.new()  # everything but the licences, shown while open
var main := VBoxContainer.new()  # Reprendre, touches, licences, overlay
var keys := VBoxContainer.new()  # the key list
var credits := preload("res://credits.gd").new()  # over the menu
var hud_button := Button.new()
var key_buttons := {}  # action -> Button showing its keys
var waiting: StringName = &""  # action whose new key is awaited
var _was_captured := false


func _ready() -> void:
	layer = 50  # under the loading veil (100)
	process_mode = PROCESS_MODE_ALWAYS
	var ink := world.seasons.colour("ink") as Color
	screen.theme = Theme.new()
	screen.theme.set_color("font_color", "Label", ink)
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.visible = false
	add_child(screen)
	var dim := ColorRect.new()
	dim.color = Color(ink, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(dim)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	screen.add_child(centre)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CREAM
	style.set_corner_radius_all(12)
	style.set_content_margin_all(24)
	panel.add_theme_stylebox_override("panel", style)
	centre.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	box.add_child(main)
	box.add_child(keys)
	main.add_theme_constant_override("separation", 10)
	_title(main, "Pause")
	_button(main, "Reprendre", close)
	_button(main, "Configuration des touches", _show.bind(keys))
	_button(main, "Licences", credits.toggle)
	_button(main, "", toggle_hud, hud_button)
	_title(keys, "Configuration des touches")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(480, 400)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	keys.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for a in ACTIONS:
		var l := Label.new()
		l.text = a[1]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
		var b := Button.new()
		b.custom_minimum_size.x = 180
		b.pressed.connect(_wait.bind(a[0]))
		grid.add_child(b)
		key_buttons[a[0]] = b
	var row := HBoxContainer.new()
	keys.add_child(row)
	_button(row, "Rétablir par défaut", reset_keys)
	_button(row, "Retour", _show.bind(main))
	add_child(credits)
	load_settings()


func _title(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 26)
	parent.add_child(l)


func _button(parent: Control, text: String, action: Callable, b := Button.new()) -> void:
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)


func load_settings() -> void:
	cfg = ConfigFile.new()
	cfg.load(path)  # no file yet: defaults
	for a in cfg.get_section_keys("keys") if cfg.has_section("keys") else []:
		var events = cfg.get_value("keys", a)
		if InputMap.has_action(a) and events is Array:
			InputMap.action_erase_events(a)
			for e in events:
				if e is InputEventKey:
					InputMap.action_add_event(a, e)
	world.hud.visible = cfg.get_value("ui", "hud", false) == true
	_refresh()


func open() -> void:
	screen.visible = true
	_show(main)
	get_tree().paused = true
	world.player.mouse_free = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	screen.visible = false
	waiting = &""
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# The browser may refuse the capture (and headless never reports it): then the next click takes it.
	world.player.mouse_free = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED


func _show(page: Control) -> void:
	main.visible = page == main
	keys.visible = page == keys
	waiting = &""
	_refresh()
	if page == main:
		main.get_child(1).grab_focus.call_deferred()  # Reprendre: keyboard navigation from there


func toggle_hud() -> void:
	world.hud.visible = not world.hud.visible
	cfg.set_value("ui", "hud", world.hud.visible)
	cfg.save(path)
	_refresh()


func _wait(action: StringName) -> void:
	_refresh()
	waiting = action
	key_buttons[action].text = "Appuyez sur une touche…"


## `action` now takes `key` (its physical key, so it stays put if the layout changes), and only it: the
## key is taken from any action that had it.
func rebind(action: StringName, key: InputEventKey) -> void:
	var e := InputEventKey.new()
	e.device = -1  # any keyboard
	e.physical_keycode = key.physical_keycode
	e.key_label = key.key_label  # what the menu shows; matching only looks at the physical key
	for a in ACTIONS:
		for old: InputEvent in InputMap.action_get_events(a[0]):
			if old.is_match(key, false) or a[0] == action:
				InputMap.action_erase_event(a[0], old)
				cfg.set_value("keys", a[0], InputMap.action_get_events(a[0]))
	InputMap.action_add_event(action, e)
	cfg.set_value("keys", action, InputMap.action_get_events(action))
	cfg.save(path)
	_refresh()


func reset_keys() -> void:
	InputMap.load_from_project_settings()
	if cfg.has_section("keys"):
		cfg.erase_section("keys")
	cfg.save(path)
	waiting = &""
	_refresh()


func _refresh() -> void:
	for a in key_buttons:
		var s := " / ".join(PackedStringArray(InputMap.action_get_events(a).map(key_name)))
		key_buttons[a].text = s if s else "—"
	hud_button.text = "Masquer l'overlay" if world.hud.visible else "Afficher l'overlay"


static func key_name(e: InputEventKey) -> String:
	if not e.keycode and e.physical_keycode >= KEY_0 and e.physical_keycode <= KEY_9:
		return char(e.physical_keycode)  # the digit row, not AZERTY's & é " '
	var k := e.keycode if e.keycode else e.key_label
	if not k and DisplayServer.get_name() != "headless" and OS.get_name() != "Web":
		k = DisplayServer.keyboard_get_keycode_from_physical(e.physical_keycode)  # Z for W on AZERTY
	var s := OS.get_keycode_string(k if k else e.physical_keycode)
	return KEY_NAMES.get(s, s)


func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if waiting:  # the awaited key; Escape cancels
		var action := waiting
		waiting = &""
		if e.keycode != KEY_ESCAPE:
			rebind(action, e)
		_refresh()
	elif e.keycode != KEY_ESCAPE:
		return
	elif credits.visible:
		credits.toggle()
	elif keys.visible and screen.visible:
		_show(main)
	elif screen.visible:
		close()
	else:
		open()
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _was_captured and not captured and not screen.visible and not credits.visible:
		open()  # the browser dropped the pointer lock (its Escape)
	_was_captured = captured
