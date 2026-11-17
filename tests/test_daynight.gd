extends SceneTree
# Run: godot --headless --path . -s tests/test_daynight.gd
# Time wraps and is moved by +/-, the sun sets at night, the sun path follows the season (46°N),
# and a season's tint survives the hour.

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


## [sunrise, sunset] hours where the sun crosses the horizon, found by stepping the minutes.
func _rise_set(d, decl: float) -> Array:
	var out := [-1.0, -1.0]
	for m in 24 * 60:
		var y0: float = d.sun_dir(m / 60.0, decl).y
		var y1: float = d.sun_dir((m + 1) / 60.0, decl).y
		if y0 < 0.0 and y1 >= 0.0:
			out[0] = (m + 0.5) / 60.0
		elif y0 >= 0.0 and y1 < 0.0:
			out[1] = (m + 0.5) / 60.0
	return out


func _hm(h: float) -> String:
	var m := roundi(h * 60.0)
	return "%02d:%02d" % [m / 60, m % 60]


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
	assert(d.sun_dir(d.NOON).y > 0.65)  # equinox: 44°
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
	var summer_set: float = _rise_set(d, d.DECLINATION[w.seasons.season])[1]
	d.set_time(summer_set - 0.25)
	assert(sun.light_color.r > sun.light_color.b * 1.5, "warm sunset light")
	assert(w.seasons.sky.sky_horizon_color.r > w.seasons.sky.sky_horizon_color.b)
	d.set_time(18.75)  # summer: the sun is still well up
	assert(sun.light_color.is_equal_approx(w.seasons.light.sun))

	# Season sun path at 46°N: noon elevation 90 - 46 + declination, longer days in summer.
	var noon_deg := [67.4, 44.0, 20.6, 44.0]  # by Season
	var day_len := []
	for s in 4:
		var decl: float = d.DECLINATION[s]
		assert(absf(rad_to_deg(asin(d.sun_dir(d.NOON, decl).y)) - noon_deg[s]) < 0.1)
		var rs := _rise_set(d, decl)
		print("%s: sunrise %s, sunset %s, noon %.1f°" % [w.seasons.NAMES[s], _hm(rs[0]), _hm(rs[1]), noon_deg[s]])
		assert(absf(rs[0] + rs[1] - 2.0 * d.NOON) < 0.05, "symmetric around solar noon")
		for h in [rs[0] - 0.25, rs[1] + 0.25, fposmod(d.NOON + 12.0, 24.0)]:
			assert(d.sun_dir(h, decl).y < 0.0, "night")
		assert(d.sun_dir(rs[0] + 0.25, decl).y > 0.0 and d.sun_dir(rs[1] - 0.25, decl).y > 0.0)
		day_len.append(rs[1] - rs[0])
	var S = w.seasons.Season
	assert(day_len[S.SUMMER] > 15.0 and day_len[S.WINTER] < 9.0)
	assert(absf(day_len[S.AUTUMN] - 12.0) < 0.1 and absf(day_len[S.SPRING] - 12.0) < 0.1)
	# apply() follows the season: low winter sun at noon, already down at 18:00 in winter.
	var hour: float = d.time
	w.seasons.set_season(S.WINTER)
	d.set_time(d.NOON)
	assert(absf(rad_to_deg(asin(sun.global_basis.z.y)) - noon_deg[S.WINTER]) < 0.2)
	d.set_time(18.0)
	assert(sun.light_color.is_equal_approx(w.seasons.light.sun * d.MOON), "winter: moon by 18:00")
	w.seasons.set_season(S.SUMMER)
	d.set_time(hour)

	# Season × hour: winter at noon dimmer than summer at noon; switching hours keeps the winter tint.
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
