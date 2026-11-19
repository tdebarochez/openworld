extends SceneTree
# Run: godot --headless --path . -s tests/test_campfires.gd
# Campfires (campfires.gd): some within ~3 km, deterministic, each listed by exactly one zone, in the
# woods below the tree line, FAR from every village, off roads, water, cabins and landmarks, no tree,
# bush, rock or flower in the clearing (even at the highest density); the camp, its collision and its
# light in full zones only, flames and smoke at every level; the light on at night, off by day, its
# flicker bounded; the crackle heard near a fire and not away from it, the ambient players a fixed few.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check():  # a failed assert() returns null from _check without stopping the run
			print("CAMPFIRES OK")
			quit()
		else:
			quit(1)
	return false


func _check():
	var c = w.camps
	var sites := []
	var n := 6
	for gx in range(-n, n):
		for gz in range(-n, n):
			var g := Vector2i(gx, gz)
			var s: Dictionary = c.camp_site(g)
			assert(s == c._camp_site(g), "campfire not a pure function of the seed")
			if not s.is_empty():
				assert(Rect2(Vector2(g) * c.GRID, Vector2.ONE * c.GRID).grow(-c.MARGIN).has_point(Vector2(s.pos.x, s.pos.z)))
				sites.append(s)
	var km2: float = pow(2 * n * c.GRID / 1000.0, 2)
	print("campfires over %.1f km2: %d (%.2f per km2), kinds %s" % [km2, sites.size(), sites.size() / km2,
		range(c.KINDS).map(func(k): return sites.filter(func(s): return s.kind == k).size())])
	assert(sites.size() >= 5, "too few campfires")
	for s: Dictionary in sites:
		var p := Vector2(s.pos.x, s.pos.z)
		assert(w.forest(p.x, p.y) >= c.OPEN and s.pos.y < w.TREE_LINE, "campfire out of the woods")
		var wooded := 0
		for i in 8:
			wooded += int(c.woods(p + Vector2.from_angle(TAU * i / 8.0) * c.RING))
		assert(wooded >= c.WOODED, "no woods round the clearing")
		for i in 8:
			var q := p + Vector2.from_angle(TAU * i / 8.0) * 2.2
			assert(w.height(q.x, q.y) > w.WATER_LEVEL + 2.0, "campfire by the water")
		assert(not w._near_line(p, w._roads_near(p, 40.0), c.CLEAR + c.ROAD_GAP + w.ROAD_HALF), "campfire by a road")
		var vg := Vector2i((p / w.VILLAGE_GRID).floor())
		for dx in range(-2, 3):
			for dz in range(-2, 3):
				var v: Dictionary = w.village_site(vg + Vector2i(dx, dz))
				if not v.is_empty():
					assert(v.centre.distance_to(p) >= c.FAR, "campfire %.0f m from a village" % v.centre.distance_to(p))
		var cg := Vector2i((p / w.CABIN_GRID).floor())
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cs: Dictionary = w.cabin_site(cg + Vector2i(dx, dz))
				if not cs.is_empty():
					for it in [cs.cabin, cs.pier]:
						assert(Vector2(it[0].x, it[0].z).distance_to(p) > c.CLEAR + w.CABIN_CLEAR, "campfire on a cabin")
		var lg := Vector2i((p / w.LANDMARK_GRID).floor())
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var ls: Dictionary = w.landmark_site(lg + Vector2i(dx, dz))
				assert(ls.is_empty() or Vector2(ls.pos.x, ls.pos.z).distance_to(p) > w.LANDMARK_CLEAR[ls.kind] + c.CLEAR, "campfire on a landmark")
	# Spacing and discoverability.
	var rng := RandomNumberGenerator.new()
	var dist := []
	var reach: float = n * c.GRID - 300.0
	for i in 500:
		var q := Vector2(rng.randf_range(-reach, reach), rng.randf_range(-reach, reach))
		dist.append(sites.reduce(func(m, s): return minf(m, q.distance_to(Vector2(s.pos.x, s.pos.z))), INF))
	dist.sort()
	print("nearest campfire from random points: median %.0f m, 90%% %.0f m" % [dist[250], dist[450]])
	for s in sites:
		for o in sites:
			assert(o == s or s.pos.distance_to(o.pos) > 2.0 * c.MARGIN - 1.0, "two campfires too close")

	# Zones: each camp listed once across its 3 x 3 zones; nothing growing in its clearing at the highest density.
	w.density = w.DENSITY_MAX
	for s: Dictionary in sites.slice(0, 4):
		var home: Vector2i = w.cell_of(s.pos)
		var seen := 0
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Vector2i = home + Vector2i(dx, dz)
				var o: Vector2 = Vector2(cell) * w.ZONE_SIZE
				var lay: Dictionary = w.layout(cell)
				for k in c.KINDS:
					for t: Transform3D in lay.camps[k]:
						seen += int((t.origin + Vector3(o.x, 0, o.y)).distance_to(s.pos) < 0.01)
				for group in [w.tree_transforms(cell, lay.mask), w.bush_transforms(cell, lay.mask), w.rock_transforms(cell, lay.mask),
						w.flower_transforms(cell, lay.mask)]:
					for list in group:
						for t: Transform3D in list:
							assert(Vector2(t.origin.x + o.x, t.origin.z + o.y).distance_to(Vector2(s.pos.x, s.pos.z)) > c.CLEAR - 1.0,
								"something growing in a campfire's clearing")
		assert(seen == 1, "campfire listed %d times" % seen)
	w.density = 1.0

	# Detail levels: flames and smoke everywhere; the camp, its collision and its light in full zones.
	var s0: Dictionary = sites[0]
	var cell: Vector2i = w.cell_of(s0.pos)
	w.daynight.set_time(23.0)
	w._process(0.016)
	assert(w.lamps_on, "not night at 23:00")
	for detail in [w.Detail.LIGHT, w.Detail.FULL]:
		w.add_zone(cell, detail)
		var zone: Node3D = w.zones[cell]
		var meshes: Array = zone.get_children().filter(func(m): return m is MultiMeshInstance3D).map(func(m): return m.multimesh.mesh)
		assert(c.flame_mesh in meshes and w.life.smoke_mesh in meshes, "no flames or smoke")
		var full: bool = detail == w.Detail.FULL
		assert((c.meshes[s0.kind] in meshes) == full, "camp model in the wrong zones")
		var shapes: Array = zone.find_children("", "CollisionShape3D", true, false).map(func(x): return x.shape)
		assert((c.shapes[s0.kind] in shapes) == full, "camp collision in the wrong zones")
		var lights: Array = zone.get_children().filter(func(x): return x.is_in_group("camp_light"))
		assert(lights.size() == (1 if full else 0), "camp light in the wrong zones")
	var light: OmniLight3D = w.zones[cell].get_children().filter(func(x): return x.is_in_group("camp_light"))[0]
	assert(light.visible and light.position.distance_to(s0.pos - w.zones[cell].position + c.LIGHT_AT) < 0.01, "campfire dark at night")
	var lo := INF
	var hi := -INF
	for i in 5000:
		var f: float = c.flicker(i * 0.0137, fposmod(i * 0.71, TAU))
		lo = minf(lo, f)
		hi = maxf(hi, f)
	assert(lo >= 0.72 - 1e-4 and hi <= 1.12 + 1e-4 and hi - lo > 0.25, "flicker out of bounds or flat: %f..%f" % [lo, hi])
	var energies := []
	for i in 4:
		c._process(0.016)
		energies.append(light.light_energy)
		OS.delay_msec(37)
	assert(energies.all(func(e): return e >= c.LIGHT_ENERGY * 0.72 - 1e-3 and e <= c.LIGHT_ENERGY * 1.12 + 1e-3), "light energy %s" % [energies])
	assert(energies.max() > energies.min(), "the light doesn't flicker")
	var night_embers: float = c.ember_mat.emission_energy_multiplier
	w.daynight.set_time(13.0)
	w._process(0.016)
	c._process(0.016)
	assert(not light.visible, "campfire light on at noon")
	assert(c.ember_mat.emission_energy_multiplier < night_embers and c.ember_mat.emission_energy_multiplier > 0.0, "embers by day")
	print("light %s, energy %s at night, embers %.1f at night / %.1f by day" % [light.light_color, energies, night_embers, c.ember_mat.emission_energy_multiplier])

	# Sound: crackling by the fire, not 60 m away; the pool stays POOL players.
	var amb = w.find_children("", "Node", false, false).filter(func(x): return x.get_script() == preload("res://ambience.gd"))[0]
	var by: Vector3 = s0.pos + Vector3(3.0, 1.0, 0.0)
	amb.update(by)
	assert(amb.fire.playing and amb.fire.position.distance_to(s0.pos) < 1.0, "no crackle by the fire")
	amb.update(s0.pos + Vector3(60.0, 1.0, 0.0))
	assert(not amb.fire.playing, "crackle away from the fire")
	for p in [by, s0.pos + Vector3(60.0, 1.0, 0.0), Vector3.ZERO, by]:
		amb.update(p)
		assert(amb.find_children("", "AudioStreamPlayer3D", true, false).size() == amb.POOL, "ambient players not bounded")
	return true
