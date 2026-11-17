extends SceneTree
# Run: godot --headless --path . -s tests/test_daynight.gd
# Time wraps and is moved by +/-, the sun sets at night, and a season's tint survives the hour.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check():  # a failed assert() returns null from _check without stopping the run
			print("DAYNIGHT OK")
			quit()
		else:
			quit(1)
	return false


func _key(keycode: Key, unicode: int, pressed: bool, physical := KEY_NONE) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = keycode
	e.physical_keycode = physical
	e.unicode = unicode
	e.pressed = pressed
	return e


func _check():
	var d = w.daynight
	var sun: DirectionalLight3D = w.seasons.sun
	d.set_time(25.5)
	assert(is_equal_approx(d.time, 1.5) and d.clock() == "01:30")
	assert(w.hud.text.contains("Heure : 01:30"))
	d.set_time(-1.0)
	assert(is_equal_approx(d.time, 23.0))

	# '+' typed on AZERTY (Shift+'=' key), '=' on QWERTY, keypad; '-' anywhere.
	assert(d.key_dir(_key(KEY_EQUAL, 43, true)) == 1)
	assert(d.key_dir(_key(KEY_EQUAL, 61, true)) == 1)
	assert(d.key_dir(_key(KEY_KP_ADD, 43, true)) == 1)
	assert(d.key_dir(_key(KEY_MINUS, 45, true)) == -1)
	assert(d.key_dir(_key(KEY_KP_SUBTRACT, 45, true)) == -1)
	assert(d.key_dir(_key(KEY_1, 38, true)) == 0)
	d.set_time(12.0)
	d._unhandled_input(_key(KEY_EQUAL, 43, true, KEY_EQUAL))  # tap
	assert(is_equal_approx(d.time, 12.0 + d.TAP))
	d._process(1.0)  # held: scrubs forward
	assert(is_equal_approx(d.time, 12.0 + d.TAP + d.SCRUB_SPEED + 24.0 / d.DAY_SECONDS))
	d._unhandled_input(_key(KEY_EQUAL, 0, false, KEY_EQUAL))  # release (no unicode)
	assert(d.held.is_empty())
	d.set_time(0.1)
	d._unhandled_input(_key(KEY_MINUS, 45, true, KEY_6))  # AZERTY '-' is the 6 key
	d._process(0.5)
	d._unhandled_input(_key(KEY_MINUS, 0, false, KEY_6))
	assert(is_equal_approx(d.time, 24.0 + 0.1 - d.TAP - 1.0 + 0.5 * 24.0 / d.DAY_SECONDS))

	# Sun high at noon, rising east, setting west, below the horizon at night (light = moon above).
	assert(d.sun_dir(d.NOON).y > 0.7)
	assert(d.sun_dir(0.0).y < -0.5)
	assert(d.sun_dir(8.0).x > 0.5 and d.sun_dir(18.0).x < -0.5)
	d.set_time(d.NOON)
	var noon_energy := sun.light_energy
	var noon_haze: Color = w.seasons.sky.sky_horizon_color
	assert(sun.global_basis.z.y > 0.7)  # light shines along -Z: downwards
	d.set_time(0.0)
	assert(sun.global_basis.z.y > 0.3, "moonlight from above")
	assert(sun.light_energy < noon_energy * 0.5 and sun.light_energy > 0.0)
	assert(sun.light_color.b > sun.light_color.r, "cool moonlight")
	var night_haze: Color = w.seasons.sky.sky_horizon_color
	assert(night_haze.v < noon_haze.v * 0.4)
	assert(w.seasons.env.fog_light_color == night_haze)
	d.set_time(18.75)
	assert(sun.light_color.r > sun.light_color.b * 1.5, "warm sunset light")
	assert(w.seasons.sky.sky_horizon_color.r > w.seasons.sky.sky_horizon_color.b)

	# Season × hour: winter at noon dimmer than summer at noon; switching hours keeps the winter tint.
	var S = w.seasons.Season
	w.seasons.set_season(S.WINTER)
	assert(is_equal_approx(d.time, 18.75), "season switch must not move the clock")
	d.set_time(d.NOON)
	assert(is_equal_approx(sun.light_energy, noon_energy * w.seasons.LIGHT[S.WINTER].energy))
	assert(sun.light_color.is_equal_approx(w.seasons.light.sun))
	assert(w.seasons.sky.sky_horizon_color.is_equal_approx(w.seasons.light.haze))
	assert(w.seasons.env.fog_depth_begin == w.seasons.light.fog)
	d.set_time(0.0)
	assert(sun.light_color.is_equal_approx(w.seasons.light.sun * d.MOON))
	w.seasons.set_season(S.SUMMER)
	assert(sun.light_color.is_equal_approx(w.seasons.base.sun * d.MOON), "season switch at night stays night")
	return true
