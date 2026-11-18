extends SceneTree
# Run: godot --headless --path . -s tests/test_landmarks.gd
# Landmarks: every kind within ~5 km, deterministic, off water (a bridge's middle over it, its ends on
# the banks), roads, villages and cabins, each listed by exactly one zone, no tree, bush or rock on
# them, shown in light and coarse zones, collision in full ones. Villages: a name each (unique here),
# one particularity at the square, clear of benches, lamps, houses and (stalls) roads. HUD and map.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check_landmarks() and _check_villages() and _check_hud():  # a failed assert() returns null
			print("LANDMARKS OK")
			quit()
		else:
			quit(1)
	return false


func _check_landmarks():
	var sites := []
	var kinds := [0, 0, 0, 0, 0]
	for gx in range(-4, 4):
		for gz in range(-4, 4):
			var g := Vector2i(gx, gz)
			var s: Dictionary = w.landmark_site(g)
			assert(s == w._landmark_site(g), "landmark not a pure function of the seed")
			if not s.is_empty():
				assert(Rect2(Vector2(g) * w.LANDMARK_GRID, Vector2.ONE * w.LANDMARK_GRID).has_point(Vector2(s.pos.x, s.pos.z)))
				sites.append(s)
				kinds[s.kind] += 1
	var km2: float = pow(8 * w.LANDMARK_GRID / 1000.0, 2)
	print("landmarks over %.0f km2: %d (%.1f per km2), per kind %s" % [km2, sites.size(), sites.size() / km2, kinds])
	assert(kinds.min() > 0, "every landmark kind should appear")
	for s: Dictionary in sites:
		var p := Vector2(s.pos.x, s.pos.z)
		var clear: float = w.LANDMARK_CLEAR[s.kind]
		assert(s.name.length() > 4, "landmark without a name")
		if s.kind == w.Landmark.BRIDGE:
			var d: Vector3 = w.landmark_transform(s).basis.x  # along the deck, scale included
			for e in [-1, 1]:
				var q: Vector3 = s.pos + d * 13.5 * e
				assert(w.height(q.x, q.z) > w.WATER_LEVEL, "bridge end in the water")
			assert(w.height(p.x, p.y) < w.WATER_LEVEL, "bridge not over water")
			for k in range(-12, 13, 3):  # the ground stays under the deck
				var q: Vector3 = s.pos + d * k
				assert(w.height(q.x, q.z) < s.pos.y + w.bridge_deck(k) - 0.2, "ground through the bridge deck")
			clear = w.BRIDGE_END * s.scale
		else:
			for i in 8:
				var q := p + Vector2.from_angle(TAU * i / 8.0) * 4.0
				assert(w.height(q.x, q.y) > w.WATER_LEVEL + 0.5, "landmark in the water")
		assert(not w._near_line(p, w._roads_near(p, 60.0), clear + w.ROAD_HALF), "landmark on a road")
		var vg := Vector2i((p / w.VILLAGE_GRID).floor())
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var v: Dictionary = w.village_site(vg + Vector2i(dx, dz))
				assert(v.is_empty() or v.centre.distance_to(p) > w.VILLAGE_REACH + 8.0, "landmark in a village")
		var cg := Vector2i((p / w.CABIN_GRID).floor())
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var c: Dictionary = w.cabin_site(cg + Vector2i(dx, dz))
				assert(c.is_empty() or Vector2(c.cabin[0].x, c.cabin[0].z).distance_to(p) > clear + w.CABIN_CLEAR, "landmark on a cabin")
	# Zones: each landmark listed once across its 3 x 3 zones (sails once with a windmill); no tree,
	# bush or rock (bar a tower's own rubble) inside its clearing, even at the highest density.
	w.density = w.DENSITY_MAX
	var checked := [0, 0, 0, 0, 0]
	for s: Dictionary in sites:
		if checked[s.kind] >= 2:
			continue
		checked[s.kind] += 1
		var home: Vector2i = w.cell_of(s.pos)
		var t: Transform3D = w.landmark_transform(s)
		var seen := 0
		var sails := 0
		var half: float = (w.BRIDGE_END * s.scale if s.kind == w.Landmark.BRIDGE else 0.0)
		var a := Vector2(s.pos.x, s.pos.z) - Vector2(t.basis.x.x, t.basis.x.z).normalized() * half
		var b := Vector2(s.pos.x, s.pos.z) + Vector2(t.basis.x.x, t.basis.x.z).normalized() * half
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Vector2i = home + Vector2i(dx, dz)
				var o: Vector2 = Vector2(cell) * w.ZONE_SIZE
				var lay: Dictionary = w.layout(cell)
				for lt: Transform3D in lay.landmarks[s.kind]:
					if (lt.origin + Vector3(o.x, 0, o.y)).distance_to(s.pos) < 0.01:
						seen += 1
				sails += lay.landmarks[w.Landmark.size()].size()
				for group in [w.tree_transforms(cell, lay.mask), w.bush_transforms(cell, lay.mask), w.rock_transforms(cell, lay.mask)]:
					for list in group:
						for tr: Transform3D in list:
							var q := Vector2(tr.origin.x, tr.origin.z) + o
							assert(q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b)) > w.LANDMARK_CLEAR[s.kind] - 1.0,
								"tree, bush or rock on a landmark (%s)" % w.LANDMARK_FILES[s.kind])
		assert(seen == 1, "%s listed %d times" % [w.LANDMARK_FILES[s.kind], seen])
		if s.kind == w.Landmark.WINDMILL:
			assert(sails >= 1, "windmill without sails")
	w.density = 1.0
	# Every detail level shows them; only full zones collide (trimesh).
	for s: Dictionary in sites.slice(0, 6):
		var cell: Vector2i = w.cell_of(s.pos)
		for detail in [w.Detail.COARSE, w.Detail.LIGHT, w.Detail.FULL]:
			w.add_zone(cell, detail)
			var zone: Node3D = w.zones[cell]
			assert(zone.get_children().any(func(n): return n is MultiMeshInstance3D and n.multimesh.mesh == w.landmark_meshes[s.kind]),
				"%s missing from a %s zone" % [w.LANDMARK_FILES[s.kind], w.Detail.keys()[detail]])
			var trimeshes: Array = zone.find_children("", "CollisionShape3D", true, false).filter(func(c): return c.shape is ConcavePolygonShape3D)
			assert(trimeshes.is_empty() != (detail == w.Detail.FULL), "landmark collision in the wrong zones")
	var sails_mat = w.landmark_meshes[w.Landmark.size()].surface_get_material(0)
	assert(sails_mat is ShaderMaterial and "TIME" in sails_mat.shader.code, "sails don't turn in their shader")
	# Distance from random points to the nearest landmark.
	var rng := RandomNumberGenerator.new()
	var dist := []
	for i in 500:
		var p := Vector2(rng.randf_range(-1800, 1800), rng.randf_range(-1800, 1800))
		dist.append(sites.reduce(func(m, s): return minf(m, p.distance_to(Vector2(s.pos.x, s.pos.z))), INF))
	dist.sort()
	print("nearest landmark from random points: median %.0f m, 90%% %.0f m, max %.0f m" % [dist[250], dist[450], dist[-1]])
	assert(dist[-1] < 1000.0, "a spot more than 1 km from any landmark")
	return true


func _check_villages():
	var names := {}
	var per_feature := [0, 0, 0]
	var stalls := 0
	for gx in range(-7, 7):
		for gz in range(-7, 7):
			var g := Vector2i(gx, gz)
			var v: Dictionary = w.village(g)
			if v.is_empty():
				continue
			var again: Dictionary = w._village(g)
			assert(again.name == v.name and again.square == v.square, "village name or square not deterministic")
			assert(v.name.length() > 2 and not names.has(v.name), "village name missing or repeated: " + v.name)
			names[v.name] = true
			per_feature[v.feature] += 1
			var roads := []
			for d in w.LINK_OFFSETS:
				roads.append(w.road(g, g + d))
			var benches: Array = v.props.filter(func(o): return o[2] != w.Prop.PLANTER)
			assert(not v.square.is_empty(), "village without its particularity")
			for it in v.square:
				var p := Vector2(it[0].x, it[0].z)
				var box: AABB = w.feature_meshes[it[2]].get_aabb()
				var r := Vector2(maxf(-box.position.x, box.end.x), maxf(-box.position.z, box.end.z)).length()
				assert(p.distance_to(v.centre) + r < w.BENCH_RADIUS - 0.5, "particularity off the square")
				assert(w._far_from(p, benches + v.lamps, r + 0.8), "particularity on a bench or a lamp")
				assert(not w.in_house(p, v.houses, r), "particularity in a house")
				if v.feature == w.Feature.MARKET:
					assert(it[2] >= 2 and not w._near_line(p, roads, w.ROAD_HALF + 0.8), "stall on a road")
					var front: Vector3 = Basis(Vector3.UP, it[1]) * Vector3.BACK
					assert(Vector2(front.x, front.z).dot((v.centre - p).normalized()) > 0.99, "stall not facing the square")
				else:
					assert(v.square.size() == 1 and it[2] == v.feature and p.distance_to(v.centre) < 0.01)
			if v.feature == w.Feature.MARKET:
				stalls += v.square.size()
			# Each item in exactly one zone.
			for it in v.square:
				var seen := 0
				for dx in range(-1, 2):
					for dz in range(-1, 2):
						var cell: Vector2i = w.cell_of(it[0]) + Vector2i(dx, dz)
						var o: Vector3 = Vector3(cell.x, 0, cell.y) * w.ZONE_SIZE
						for t: Transform3D in w.layout(cell).features[it[2]]:
							seen += int((t.origin + o).distance_to(it[0]) < 0.01)
				assert(seen == 1, "particularity listed %d times" % seen)
	print("villages %d, names unique, wells/fountains/markets %s, %.1f stalls per market; e.g. %s" % [
		names.size(), per_feature, float(stalls) / maxi(per_feature[2], 1), names.keys().slice(0, 8)])
	assert(per_feature.min() > 0, "every particularity should appear")
	assert(stalls >= per_feature[2] * 2, "markets should have two or three stalls")
	return true


func _check_hud():
	# Near a village: its name and particularity at the top; near a landmark (even a village's windmill): its name.
	var v: Dictionary = w.village(Vector2i(0, 0)) if not w.village(Vector2i(0, 0)).is_empty() else w.village(Vector2i(0, 1))
	w.player.position = Vector3(v.centre.x + 20.0, 50.0, v.centre.y)
	w._place_at = Vector3.INF
	w._update_place()
	assert(w.place.text.begins_with(v.name) and w.FEATURE_NAMES[v.feature] in w.place.text, "HUD: " + w.place.text)
	print("HUD near %s: %s" % [v.name, w.place.text.replace("\n", " / ")])
	var s: Dictionary = w.landmark_site(Vector2i(0, 0))
	for gx in range(-2, 2):
		if s.is_empty():
			s = w.landmark_site(Vector2i(gx, 1))
	w.player.position = s.pos + Vector3(10.0, 2.0, 0.0)
	w._place_at = Vector3.INF
	w._update_place()
	assert(w.place.text.begins_with(s.name), "HUD at a landmark: " + w.place.text)
	print("HUD near %s: %s" % [s.name, w.place.text.replace("\n", " / ")])
	# Map: village names as labels over generated zones.
	var map = w.find_children("", "TextureRect", true, false)[0]
	w.player.position = Vector3(v.centre.x, 50.0, v.centre.y)
	map.refresh()
	assert(map.names.any(func(l): return l.visible and l.text == v.name), "village name not on the map")
	return true
