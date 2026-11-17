extends SceneTree
# Run: godot --headless --path . -s tests/test_clouds.gd
# The cloud dome follows the camera and drifts with the wind, winter is more overcast than summer,
# clouds darken at night and turn warm at sunset.

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
	var cam: Camera3D = w.player.camera
	assert(c.mesh.radius < cam.far, "dome inside the far plane")
	assert(c.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

	# Follows the camera; the wind moves the clouds.
	w.player.global_position += Vector3(300, 0, -150)
	var drift: Vector2 = c.drift
	c._process(10.0)
	assert(c.global_position.is_equal_approx(cam.global_position))
	assert(not c.drift.is_equal_approx(drift), "no wind drift")

	# Season: winter overcast, summer fair weather (cover eases towards the season's value).
	var S = w.seasons.Season
	w.seasons.set_season(S.WINTER)
	c._process(100.0)
	var winter: float = c.cover
	w.seasons.set_season(S.SUMMER)
	c._process(0.5)
	assert(c.cover < winter and c.cover > c.COVER[S.SUMMER], "eases, no jump")
	c._process(100.0)
	print("cover: summer %.2f, winter %.2f" % [c.cover, winter])
	assert(winter > c.cover + 0.3)

	# Light: bright at noon, dim at night (no glow), warm at sunset.
	var d = w.daynight
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
	assert((c.material_override as ShaderMaterial).get_shader_parameter("lit") == dusk)
	return true
