extends SceneTree
# Run: godot --headless --path . -s tests/test_seasons.gd
# Season switching recolours already attached zones in place and summer restores today's look.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		# A failed assert() aborts _check (returning null) without stopping the run, so check the result.
		if _check():
			print("SEASONS OK")
			quit()
		else:
			quit(1)
	return false


## All tree MultiMeshes of loaded zones: [{mm, kind, pos: Array[Vector3]}].
func _trees() -> Array:
	var out := []
	for zone in w.zones.values():
		for mmi in zone.get_children():
			if mmi.has_meta("trees"):
				var pos := []
				for t in mmi.get_meta("trees"):
					pos.append(zone.position + t.origin)
				out.append({"mm": mmi.multimesh, "kind": w.species.find(mmi.multimesh.mesh) / w.TREE_VARIANTS, "pos": pos})
	return out


## Instance colour as uploaded (the headless renderer only keeps whole buffers, not set_instance_color).
func _colour(mm: MultiMesh, i: int) -> Color:
	var b := mm.buffer
	return Color(b[i * 16 + 12], b[i * 16 + 13], b[i * 16 + 14], b[i * 16 + 15])


func _check():
	var s = w.seasons
	var S = s.Season
	# Summer palette = the colours world bakes into the terrain (the shader's category keys).
	assert(s.GROUND[S.SUMMER] == [w._ground_color(0, 1), w._ground_color(5, 0.5), w._ground_color(30, 1), w._ground_color(5, 1)])
	var trees := _trees()
	var kinds := {}
	for t in trees:
		kinds[t.kind] = true
	assert(kinds.size() == 3, "expected all species around the spawn")
	var sun_energy: float = w.seasons.sun.light_energy
	var water: Color = w.water_mat.albedo_color

	for season in [S.AUTUMN, S.WINTER, S.SPRING, S.SUMMER]:
		s.set_season(season)
		assert(w.hud.text.contains(s.NAMES[season]))
		var bare := 0
		var deciduous := 0
		for t in trees:
			for i in t.pos.size():
				var c := _colour(t.mm, i)
				assert(c.is_equal_approx(s.leaf_color(t.kind, t.pos[i])), "stale colour on a loaded zone: season %d kind %d %s vs %s" % [season, t.kind, c, s.leaf_color(t.kind, t.pos[i])])
				if season == S.SUMMER:
					assert(c.is_equal_approx(w.leaf_tint(t.pos[i])))
				if t.kind != w.TreeKind.CONIFER:
					deciduous += 1
					bare += int(c.a == 0.0)
					if season == S.AUTUMN:
						assert(c.r > c.g and c.g >= c.b, "autumn leaves should be warm, got %s" % c)
				elif season != S.WINTER:
					assert(c.is_equal_approx(w.leaf_tint(t.pos[i])), "conifers stay green")
		var conifer_mat: Material = w.species[0].surface_get_material(1)
		var oak_mat: StandardMaterial3D = s.leaf_mats[w.TreeKind.OAK * w.TREE_VARIANTS]
		match season:
			S.WINTER:
				assert(bare > deciduous * 0.8, "deciduous trees should be (nearly) bare: %d/%d" % [bare, deciduous])
				assert(conifer_mat is ShaderMaterial)
				assert(oak_mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR)
				assert(w.water_mat.albedo_color == s.ICE)
				assert(s.snow.emitting)
				assert(w.seasons.sun.light_energy < sun_energy)
			S.SUMMER:
				assert(bare == 0)
				assert(conifer_mat == s.leaf_mats[0])
				assert(oak_mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED)
				assert(oak_mat.albedo_color == s.leaf_albedo[w.TreeKind.OAK * w.TREE_VARIANTS])
				assert(w.water_mat.albedo_color == water)
				assert(w.seasons.sun.light_energy == sun_energy)
				assert(not s.snow.emitting)
			_:
				assert(bare == 0)
		var to: PackedVector3Array = w.terrain_mat.get_shader_parameter("to")
		var grass: Color = s.GROUND[season][3]
		assert(to[3].is_equal_approx(Vector3(grass.r, grass.g, grass.b)))

	# Rewritten buffers keep each tree's transform (3x4 row-major layout).
	var t0: Transform3D = w.zones.values()[0].get_children().filter(func(n): return n.has_meta("trees"))[0].get_meta("trees")[0]
	var b: PackedFloat32Array = trees[0].mm.buffer
	var back := Transform3D(Vector3(b[0], b[4], b[8]), Vector3(b[1], b[5], b[9]), Vector3(b[2], b[6], b[10]), Vector3(b[3], b[7], b[11]))
	assert(back.is_equal_approx(t0), "transform mangled: %s vs %s" % [back, t0])

	# A zone attached later (here in autumn) is recoloured by the next switch too.
	s.set_season(S.AUTUMN)
	var far := Vector2i(20, 20)
	w.add_zone(far)
	s.set_season(S.WINTER)
	var found := false
	for mmi in w.zones[far].get_children():
		if mmi.has_meta("trees"):
			var kind: int = w.species.find(mmi.multimesh.mesh) / w.TREE_VARIANTS
			var p: Vector3 = w.zones[far].position + mmi.get_meta("trees")[0].origin
			assert(_colour(mmi.multimesh, 0).is_equal_approx(s.leaf_color(kind, p)))
			found = true
	assert(found, "no trees in the far zone")
	s.set_season(S.SUMMER)
	return true
