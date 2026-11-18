extends SceneTree
# Run: godot --headless --path . -s tests/test_cats.gd
# Village cats: 0-3 per village, deterministic, each on its own bench; every coat and pose shows up;
# the models sit on the seat with only the tail hanging (in front of the edge, in the air); the tail
# shader swings it; full zones carry them, others don't; seasons leave them alone.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check():  # a failed assert() returns null from _check without stopping the run
			print("CATS OK")
			quit()
		else:
			quit(1)
	return false


func _check():
	var coats := {}
	var poses := {}
	var villages := 0
	var cats := 0
	var cat_village := Vector2i(9999, 0)
	for gx in range(-5, 5):
		for gz in range(-5, 5):
			var g := Vector2i(gx, gz)
			var v: Dictionary = w.village(g)
			if v.is_empty():
				continue
			villages += 1
			assert(w._village(g).cats == v.cats, "cats not deterministic")
			assert(v.cats.size() <= w.MAX_CATS)
			var benches: Array = v.props.filter(func(o): return o[2] != w.Prop.PLANTER)
			var used := []
			for cat in v.cats:
				var bench: Array = [cat[0], cat[1]]
				assert(benches.any(func(b): return [b[0], b[1]] == bench), "cat off a bench")
				assert(not bench in used, "two cats on one bench")
				used.append(bench)
				assert(absf(cat[4]) <= w.CAT_SLIDE)
				coats[cat[3]] = true
				poses[cat[2]] = true
			cats += v.cats.size()
			if not v.cats.is_empty() and cat_village.x == 9999:
				cat_village = g
	print("cats %d over %d villages, coats %s, poses %s" % [cats, villages, coats.keys(), poses.keys()])
	assert(coats.size() == w.cat_coats.size() and poses.size() == w.CatPose.size())
	assert(cats > villages / 2 and cats < villages * w.MAX_CATS)

	# Models on the seat (bench frame, the cat at either end of its slide): above the seat or sunk at most
	# 3 cm into it, clear of the backrest and the seat's ends, except the tail, which hangs in front of the
	# edge. Swung vertices are all there, below the seat top, even at the widest swing.
	var max_swing := 0.6  # rad: above the shader's widest, 1.3 × sway
	assert("sway = 0.35" in w.cat_mat.shader.code)
	for pose in w.cat_meshes.size():
		var mesh: ArrayMesh = w.cat_meshes[pose]
		var swung := 0
		for s in mesh.get_surface_count():
			var a := mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
			var cols: PackedColorArray = a[Mesh.ARRAY_COLOR]
			var uvs: PackedVector2Array = a[Mesh.ARRAY_TEX_UV]
			for i in verts.size():
				for slide in [-w.CAT_SLIDE, w.CAT_SLIDE]:
					var p: Vector3 = verts[i] + Vector3(slide, w.SEAT_TOP, w.SEAT_FRONT)
					assert(absf(p.x) < 0.8 and p.z > -0.18, "cat past the seat's end or in the backrest")
					var hanging: bool = p.z > w.SEAT_FRONT + 0.005
					assert(p.y > w.SEAT_TOP - 0.03 or hanging, "cat sunk into the seat")
					assert(p.y > w.SEAT_TOP - 0.001 or p.z < w.SEAT_FRONT or hanging, "cat clipping the seat edge")
				if s == 0 and cols[i].a > 0.0:
					swung += 1
					var lp := verts[i] - Vector3(uvs[i].x, uvs[i].y, 0)
					assert(verts[i].z + w.SEAT_FRONT > w.SEAT_FRONT + 0.005 and verts[i].y < 0.0, "swung vertex on the seat")
					assert(absf(uvs[i].y) < 0.05 and absf(lp.x) < 0.05, "tail pivot off the edge")
					for ang in [-max_swing, max_swing]:
						assert(lp.rotated(Vector3.BACK, ang * cols[i].a).y + uvs[i].y < 0.0, "tail swings into the seat")
		assert(swung >= 12, "no tail to swing")
		assert(mesh.surface_get_material(0) == w.cat_mat)
	var code: String = w.cat_mat.shader.code
	assert("TIME" in code and "COLOR.a" in code and "VERTEX.xy" in code, "tail not animated")

	# Zones: the village's full zone has its cats, coloured by coat; lighter zones have none.
	var v: Dictionary = w.village(cat_village)
	var cell: Vector2i = w.cell_of(v.cats[0][0])
	var lay: Dictionary = w.layout(cell)
	var n := 0
	for pose in lay.cats.size():
		n += lay.cats[pose][0].size()
		for c in lay.cats[pose][1]:
			assert(c in w.cat_coats)
	assert(n >= 1 and n <= v.cats.size())
	assert(w._build_zone(cell, w.Detail.LIGHT).cats.is_empty())
	w.add_zone(cell)
	var found := 0
	for mmi in w.zones[cell].get_children():
		if mmi is MultiMeshInstance3D and mmi.multimesh.mesh in w.cat_meshes:
			found += mmi.multimesh.instance_count
			assert(mmi.multimesh.use_colors)
	assert(found == n, "cats missing from the attached zone")

	# Seasons swap shared materials (leaves, roofs, flowers): never the cats'.
	var mats: Array = w.cat_meshes.map(func(m): return range(m.get_surface_count()).map(m.surface_get_material))
	for s in w.seasons.Season.values():
		w.seasons.set_season(s)
		assert(w.cat_meshes.map(func(m): return range(m.get_surface_count()).map(m.surface_get_material)) == mats)
	w.seasons.set_season(w.seasons.Season.SUMMER)
	return true
