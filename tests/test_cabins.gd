extends SceneTree
# Run: godot --headless --path . -s tests/test_cabins.gd
# Lakeside cabins: some within ~2 km, every kind, deterministic, cabin on dry ground facing the water
# and its pier's end over the lake, off villages and roads, shown exactly once across zone edges,
# no tree, bush or rock on them; then the player stands on a pier's deck.

var w
var frames := 0
var site: Dictionary
var spot: Vector3


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _check_sites() -> bool:
	var sites := []
	var kinds := [0, 0, 0]
	for gx in range(-8, 8):
		for gz in range(-8, 8):
			var g := Vector2i(gx, gz)
			var s: Dictionary = w.cabin_site(g)
			assert(s == w._cabin_site(g), "cabin site not a pure function of the seed")
			if not s.is_empty():
				sites.append(s)
				kinds[s.kind] += 1
	print("cabins over 4 x 4 km: %d, per kind %s" % [sites.size(), kinds])
	assert(sites.size() >= 20 and kinds.min() > 0, "every cabin kind should appear")
	for s: Dictionary in sites:
		var c: Vector3 = s.cabin[0]
		var p: Vector3 = s.pier[0]
		var rot := Basis(Vector3.UP, s.pier[1])
		var cb: AABB = w.cabin_boxes[s.kind]
		var pb: AABB = w.cabin_boxes[w.CABIN_KINDS + s.kind]
		assert(is_equal_approx(s.cabin[1], s.pier[1]) and p.y == w.WATER_LEVEL)
		var to_pier := Vector2(p.x - c.x, p.z - c.z)
		assert(to_pier.normalized().dot(Vector2((rot * Vector3.BACK).x, (rot * Vector3.BACK).z)) > 0.99, "cabin not facing its pier")
		for x in [cb.position.x, cb.end.x]:  # cabin on dry ground
			for z in [cb.position.z, cb.end.z]:
				var q: Vector3 = c + rot * Vector3(x, 0, z)
				assert(w.height(q.x, q.z) > w.WATER_LEVEL + 0.3, "cabin corner in the water")
		for x in [pb.position.x, 0.0, pb.end.x]:  # pier end (and its boat) over the lake
			var q: Vector3 = p + rot * Vector3(x, 0, pb.end.z)
			assert(w.height(q.x, q.z) < w.WATER_LEVEL - 0.3, "pier end not over water")
		var cp := Vector2(c.x, c.z)
		assert(not w._near_line(cp, w._roads_near(cp, 30.0), w.ROAD_HALF + 5.0), "cabin on a road")
		var vg := Vector2i((cp / w.VILLAGE_GRID).floor())
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var v: Dictionary = w.village(vg + Vector2i(dx, dz))
				if not v.is_empty():
					assert(cp.distance_to(v.centre) > 50.0, "cabin in a village")
	# Zones: each cabin and pier listed by exactly one zone; nothing grows on or around them.
	# Checked: the first four, and every one whose clearing crosses a zone edge.
	var checked := 0
	var near_edge := 0
	for s: Dictionary in sites:
		var c: Vector3 = s.cabin[0]
		var p: Vector3 = s.pier[0]
		var end: Vector3 = p + Basis(Vector3.UP, s.pier[1]) * Vector3(0, 0, w.cabin_boxes[w.CABIN_KINDS + s.kind].end.z)
		var home: Vector2i = w.cell_of(c)
		var edge: bool = w.cell_of(p) != home or w.cell_of(end) != home \
			or maxf(absf(c.x - home.x * w.ZONE_SIZE), absf(c.z - home.y * w.ZONE_SIZE)) > w.ZONE_SIZE / 2.0 - w.CABIN_CLEAR
		if not edge and checked >= 4:
			continue
		checked += 1
		near_edge += int(edge)
		var seen := [0, 0]
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Vector2i = home + Vector2i(dx, dz)
				var origin: Vector3 = Vector3(cell.x, 0, cell.y) * w.ZONE_SIZE
				var lay: Dictionary = w.layout(cell)
				for j in 2:
					for t: Transform3D in lay.cabins[j * w.CABIN_KINDS + s.kind]:
						if (t.origin + origin).distance_to(c if j == 0 else p) < 0.01:
							seen[j] += 1
				var a := Vector2(c.x, c.z) - Vector2(origin.x, origin.z)
				var b := Vector2(end.x, end.z) - Vector2(origin.x, origin.z)
				for group in [w.tree_transforms(cell, lay.mask), w.bush_transforms(cell, lay.mask), w.rock_transforms(cell, lay.mask)]:
					for list in group:
						for t: Transform3D in list:
							var q := Vector2(t.origin.x, t.origin.z)
							assert(q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b)) > w.CABIN_CLEAR - 1.0,
								"tree, bush or rock on a cabin or its pier")
		assert(seen == [1, 1], "cabin/pier shown %s times" % [seen])
	print("cabins checked in their 3 x 3 zones: %d, %d of them across a zone edge" % [checked, near_edge])
	assert(near_edge > 0, "no cabin crosses a zone edge: the edge checks tested nothing")
	# Light zones show cabins too, without collision.
	site = sites[0]
	var cell: Vector2i = w.cell_of(site.cabin[0])
	w.add_zone(cell, w.Detail.LIGHT)
	var shown: bool = w.zones[cell].get_children().any(func(n): return n is MultiMeshInstance3D and n.multimesh.mesh == w.cabin_meshes[site.kind])
	assert(shown, "cabin missing from a light zone")
	# Winter snows on the cabins' roofs (surface 1), not on the piers.
	w.seasons.set_season(w.seasons.Season.WINTER)
	assert(w.cabin_meshes.slice(0, w.CABIN_KINDS).all(func(m): return m.surface_get_material(1) is ShaderMaterial), "no snow on the cabin roofs")
	assert(not w.cabin_meshes.slice(w.CABIN_KINDS).any(func(m): return m.surface_get_material(1) is ShaderMaterial), "snow on a pier")
	w.seasons.set_season(w.seasons.Season.SUMMER)
	assert(not w.cabin_meshes.any(func(m): return m.surface_get_material(1) is ShaderMaterial), "summer cabin roofs")
	return true


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if not _check_sites():  # a failed assert() returns null without stopping the run
			quit(1)
			return true
		# Stand on the pier's deck 4 m out, over the water.
		spot = site.pier[0] + Basis(Vector3.UP, site.pier[1]) * Vector3(0, 2.0, 4.0)
		for cell in w.missing_cells_near(spot):
			w.add_zone(cell, w.wants_detail(spot, cell))
		w.player.position = spot
		w.player.velocity = Vector3.ZERO
		assert(w.height(spot.x, spot.z) < w.WATER_LEVEL, "the deck there should be over water")
	if frames == 200:
		var y: float = w.player.global_position.y
		assert(absf(y - (w.WATER_LEVEL + 0.45 + 1.0)) < 0.15, "not standing on the pier deck, y=%f" % y)
		assert(Vector2(w.player.global_position.x - spot.x, w.player.global_position.z - spot.z).length() < 0.2)
		print("CABINS OK (player on the deck at y=%.2f)" % y)
		quit()
	return false
