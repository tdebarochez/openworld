extends SceneTree
# Run: godot --headless --path . -s tests/test_palette.gd
# assets/palette.json loads and every colour of the scene comes from it: model materials (from
# tools/make_*.py), terrain keys, water, lamps, village props, sky, haze and sun.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check():
			print("PALETTE OK")
			quit()
		else:
			quit(1)
	return false


## The palette colour within glTF/8-bit rounding of `c` (rgb), or "" if none.
func _name(c: Color) -> String:
	for n in w.seasons.palette.colours:
		var p: Color = w.seasons.colour(n)
		if absf(p.r - c.r) < 0.004 and absf(p.g - c.g) < 0.004 and absf(p.b - c.b) < 0.004:
			return n
	return ""


func _check():
	var s = w.seasons
	assert(s.palette.colours.size() >= 12, "palette not loaded")
	assert(s.colour("grass") == Color.html(s.palette.colours.grass) and s.colour("#102030") == Color.html("#102030"))
	for season in s.SEASON_KEYS:  # every season entry resolves (a name or a hex value)
		assert(s.palette.ground[season].size() == 5 and s.palette.light.has(season))
	assert(s.GROUND[s.Season.SUMMER] == s.colours(s.palette.ground.summer))

	# Model materials: every surface of every model is a palette colour (summer leaves before tinting).
	var meshes: Array = w.species + w.bush_meshes + w.rock_meshes + w.house_meshes
	for f in w.flowers:
		meshes.append(f.mesh)
	var n := 0
	for m: Mesh in meshes:
		for i in m.get_surface_count():
			var mat := m.surface_get_material(i) as StandardMaterial3D
			var albedo := mat.albedo_color
			if mat in s.leaf_mats:  # tintable leaves: albedo kept by seasons.gd
				albedo = s.leaf_albedo[s.leaf_mats.find(mat)]
			assert(_name(albedo) != "", "%s surface %d: %s is not in the palette" % [mat.resource_name, i, albedo])
			n += 1
	assert(n > 80)
	assert(_name(w.house_meshes[0].surface_get_material(1).albedo_color) == "terracotta", "house_0 roof")

	# Scene colours set in GDScript.
	for c: Color in w.ground:
		assert(_name(c) != "", "terrain key %s" % c)
	assert(_name(w.water_mat.albedo_color) == "water" and _name(w.road_color) == "ochre")
	assert(_name(w.lamp_color) == "lamp" and _name(w.lamp_glass.albedo_color) == "cream")
	assert(_name(w.lamp_meshes[0].surface_get_material(0).albedo_color) == "ink")
	for m: Mesh in w.prop_meshes:
		for i in m.get_surface_count():
			assert(_name(m.surface_get_material(i).albedo_color) != "", "prop colour")
	assert(_name(s.base.top) == "sky" and _name(s.base.haze) == "haze" and _name(s.base.sun) == "sun")
	return true
