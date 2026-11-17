extends SceneTree
# Run: godot --headless --path . -s tests/test_clouds.gd
# Three cloud layers at real altitudes; every genus shows through the N presets; the weather and the
# wind drift follow the game clock (scrubbing back restores them, continuous across midnight);
# rain/snow only under nimbostratus or a cumulonimbus overhead, lightning only with a cumulonimbus;
# winter is greyer than summer, storms are a summer thing; clouds darken at night and warm at sunset.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check():  # a failed assert() returns null from _check without stopping the run
			print("CLOUDS OK")
			quit()
		else:
			quit(1)
	return false


func _check():
	var c = w.find_children("", "MeshInstance3D", false, false).filter(
		func(n): return n.get_script() == preload("res://clouds.gd"))[0]
	var wx = w.weather
	var d = w.daynight
	var G = wx.G
	var S = w.seasons.Season
	var mat: ShaderMaterial = c.material_override
	var cam: Camera3D = w.player.camera
	assert(c.mesh.radius < cam.far, "dome inside the far plane")
	assert(c.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

	# Layer planes within each layer's real altitude range, high above middle above low.
	var hs: Array = wx.HEIGHTS
	assert(hs[0] >= 5000.0 and hs[0] <= 13000.0 and hs[1] >= 2000.0 and hs[1] <= 7000.0 and hs[2] > 0.0 and hs[2] <= 2000.0)
	assert(mat.get_shader_parameter("heights") == Vector3(hs[0], hs[1], hs[2]))

	# The dome follows the camera.
	w.player.global_position += Vector3(300, 0, -150)
	c._process(0.0)
	assert(c.global_position.is_equal_approx(cam.global_position))

	# Drift and weather follow the game clock: scrubbing forward then back restores both.
	d.set_time(11.0)
	wx._process(0.0)
	c._process(0.0)
	var drift0: Vector3 = c.drift
	var amt0: PackedFloat32Array = wx.amt
	d.held = {KEY_EQUAL: 1}  # hold '+': 2 game hours per second
	for i in 120:
		d._process(1.0 / 60.0)
		wx._process(1.0 / 60.0)
		c._process(1.0 / 60.0)
	assert(not c.drift.is_equal_approx(drift0), "scrubbing moves the clouds")
	d.held = {KEY_MINUS: -1}
	for i in 120:
		d._process(1.0 / 60.0)
		wx._process(1.0 / 60.0)
		c._process(1.0 / 60.0)
	d.held = {}
	d.set_time(11.0)
	wx._process(0.0)
	c._process(0.0)
	assert(c.drift.is_equal_approx(drift0) and wx.amt == amt0, "back to the same hour: same sky")
	# At normal speed the drift moves a little every frame, the low layer ~10 m/s, high ones faster.
	var prev: Vector3 = c.drift
	for i in 30:
		d._process(1.0 / 60.0)
		c._process(1.0 / 60.0)
		var step: Vector3 = c.drift - prev
		assert(step.z > 0.1 and step.z < 0.3 and step.x > step.z, "drift step %s" % step)
		prev = c.drift
	# Across midnight the game clock (and so the weather) keeps going.
	d.set_time(23.99)
	var before: float = d.hours()
	d._process(1.0)
	assert(d.time < 1.0 and is_equal_approx(d.hours(), before + 24.0 / d.DAY_SECONDS))

	# The schedule: deterministic, continuous, fair at first, greyer in winter, stormier in summer.
	assert(wx.state(123.4, S.AUTUMN) == wx.state(123.4, S.AUTUMN))
	var grey := [0.0, 0.0, 0.0, 0.0]
	var storms := [0.0, 0.0, 0.0, 0.0]
	for s in [S.SUMMER, S.WINTER]:
		var last: PackedFloat32Array = wx.state(0.0, s)
		for i in 20000:
			var a: PackedFloat32Array = wx.state(i * 0.1, s)
			for g in G.size():
				assert(absf(a[g] - last[g]) < 0.15, "weather jumps at %.1f h" % (i * 0.1))
				grey[s] += a[g] * wx.DIM[g]
			storms[s] += a[G.CB]
			last = a
	print("grey: summer %.0f winter %.0f; storms: summer %.0f winter %.0f" % [grey[0], grey[2], storms[0], storms[2]])
	assert(grey[S.WINTER] > grey[S.SUMMER] * 1.3 and storms[S.SUMMER] > storms[S.WINTER] * 2.0)
	assert(wx.state(10.0, S.WINTER)[G.CU] > 0.3, "the game starts in fair weather")

	# Every genus through the presets: on its layer's uniform, in the HUD; rain, snow, lightning.
	var uniform := {G.CI: ["hi_now", 0], G.CC: ["hi_now", 1], G.CS: ["hi_now", 2], G.AC: ["mid_now", 0],
		G.AS: ["mid_now", 1], G.NS: ["mid_now", 2], G.SC: ["low_now", 0], G.ST: ["low_now", 1], G.CU: ["low_now", 2]}
	var seen := {}
	for season in [S.SUMMER, S.WINTER]:
		w.seasons.set_season(season)
		for p in range(1, wx.PRESETS.size()):
			wx.set_preset(p)
			c._process(0.0)
			var g: int = wx.amt.find(_max(wx.amt))  # the preset's main genus
			seen[g] = true
			assert(w.hud.text.contains(wx.NAMES[g]), "HUD shows %s" % wx.NAMES[g])
			if g == G.CB:
				var storm: Vector4 = mat.get_shader_parameter("storm")
				assert(storm.z == wx.amt[G.CB] and Vector2(storm.x, storm.y) == wx.storm)
			else:
				var u: Vector3 = mat.get_shader_parameter(uniform[g][0])
				assert(u[uniform[g][1]] > 0.5, "%s on its layer" % wx.NAMES[g])
			var wet: bool = g == G.NS or wx.storm_dist < wx.STORM_BASE
			assert((wx.rain > 0.05) == wet, "rain with %s" % wx.PRESETS[p][0])
			assert(w.seasons.snow.emitting == (wet and season == S.WINTER))
			assert(wx.rain_fx.emitting == (wet and season != S.WINTER))
			if g in [G.CI, G.CC, G.CU] or (g == G.CB and not wet):
				assert(wx.overcast < 0.1, "bright under %s" % wx.PRESETS[p][0])
			if g == G.NS or (g == G.CB and wet):
				assert(wx.overcast > 0.8, "dark under %s" % wx.PRESETS[p][0])
			# 30 s of lightning: strikes only with a cumulonimbus; the thunder comes later.
			wx.bolt.z = 99.0
			wx.thunder.clear()
			var flashed := false
			for i in 300:
				wx._lightning(0.1, cam.global_position)
				flashed = flashed or wx.flash > 0.1
			assert(flashed == (g == G.CB), "lightning with %s" % wx.PRESETS[p][0])
			wx.bolt.z = 99.0
			wx._lightning(0.0, cam.global_position)
	assert(seen.size() == G.size(), "every genus has a preset")
	w.seasons.set_season(S.SUMMER)
	# A strike flashes the scene through daynight (sky and ambient), its thunder follows at 343 m/s.
	var noon_ambient: float = w.seasons.env.ambient_light_energy
	var p0: Vector3 = cam.global_position
	wx.thunder.clear()
	wx.strike(Vector2(p0.x + 3430.0, p0.z))
	wx._lightning(0.0, p0)
	d.apply()
	assert(w.seasons.env.ambient_light_energy > noon_ambient * 2.0, "flash")
	assert(wx.thunder.size() == 1 and absf(wx.thunder[0][0] - 10.0) < 0.01, "thunder 10 s after a strike 3.4 km away")
	wx.bolt.z = 99.0
	wx._lightning(0.0, p0)

	# Overcast dims the sun: nimbostratus vs clear.
	wx.set_preset(G.CU + 1)
	d.set_time(d.NOON)
	var clear_energy: float = w.seasons.sun.light_energy
	var clear_sky: Color = w.seasons.sky.sky_horizon_color
	wx.set_preset(G.NS + 1)
	d.apply()
	assert(w.seasons.sun.light_energy < clear_energy * 0.5)
	var dark: Color = w.seasons.sky.sky_top_color
	assert(w.seasons.sky.sky_horizon_color.v < clear_sky.v * 0.8 and dark.s < 0.15, "grey sky %s" % dark)

	# Light: bright at noon, dim at night (no glow), warm at sunset (fair-weather cumulus).
	wx.set_preset(G.CU + 1)
	d.set_time(d.NOON)
	c._process(0.0)
	var noon: Color = c.lit
	d.set_time(0.0)
	c._process(0.0)
	var night: Color = c.lit
	d.set_time(20.5)  # summer sunset
	c._process(0.0)
	var dusk: Color = c.lit
	print("lit: noon %s, night %s, dusk %s" % [noon, night, dusk])
	assert(noon.v > 0.8 and night.v < noon.v * 0.4)
	assert(night.b > night.r, "cool night tint")
	assert(dusk.r > dusk.b * 1.5, "warm sunset")
	assert(mat.get_shader_parameter("lit") == dusk)
	wx.set_preset(0)
	return true


static func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m
