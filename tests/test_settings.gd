extends SceneTree
# Run: godot --headless --path . -s tests/test_settings.gd
# O (density): a higher density keeps every object and adds more; loaded zones get rebuilt in place
# without dropping the player. P (view distance): fog end, camera far plane and streaming radius follow.
# Zones beyond NEAR_DIST are light (terrain, trees, houses, water; no rocks, flowers or collision) and
# get their full build back when the player comes near, while the ones left behind go light.

var w
var frames := 0
var phase := 0
var trees_before := 0
var zones_before := 0
var target := Vector2i.ZERO


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _tree_count() -> int:
	var n := 0
	for zone in w.zones.values():
		for c in zone.get_children():
			if c.has_meta("trees"):
				n += c.multimesh.instance_count
	return n


func _press(code: Key) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = true
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _settled() -> bool:
	return w.jobs.is_empty() and w.missing_cells_near(w.player.global_position).is_empty()


## A zone's detail as seen in its nodes: [has collision, multimesh count].
func _nodes(cell: Vector2i) -> Array:
	var kids: Array = w.zones[cell].get_children()
	return [kids.any(func(k): return k is StaticBody3D), kids.filter(func(k): return k is MultiMeshInstance3D).size()]


func _physics_process(_delta: float) -> bool:
	frames += 1
	var p: Vector3 = w.player.global_position
	if frames == 30:
		# Steps of 0.5 (density) and 100 m (view), wrapping at both ends; FPS counter shown.
		assert(w._step(9.5, 0.5, 0.5, 10.0) == 10.0 and w._step(10.0, 0.5, 0.5, 10.0) == 0.5)
		assert(w._step(0.5, -0.5, 0.5, 10.0) == 10.0)
		assert(w._step(2900.0, 100.0, 200.0, 3000.0) == 3000.0 and w._step(3000.0, 100.0, 200.0, 3000.0) == 200.0)
		assert(w._step(200.0, -100.0, 200.0, 3000.0) == 3000.0)
		assert(w.fps.text.contains("FPS") and w.fps.text.contains("polygones"))
		# Pure placement: density 2 = density 1's trees plus more, same order.
		var cell := Vector2i(2, -1)
		var one: Array = w.tree_transforms(cell)
		w.density = 2.0
		var two: Array = w.tree_transforms(cell)
		w.density = 1.0
		for m in one.size():
			assert(two[m].slice(0, one[m].size()) == one[m], "density 2 moved existing trees")
		# Default view (200 m) is all within NEAR_DIST: every zone is full.
		var FULL: int = w.Detail.FULL
		assert(w.built.values().all(func(b): return b[1] == FULL))
		# Detail by distance from the origin (cells not built yet, so no hysteresis).
		assert(w.wants_detail(Vector3.ZERO, Vector2i(3, 0)) == w.Detail.LIGHT)  # 320 m
		assert(w.wants_detail(Vector3.ZERO, Vector2i(8, 0)) == w.Detail.LIGHT)  # 960 m
		assert(w.wants_detail(Vector3.ZERO, Vector2i(9, 0)) == w.Detail.COARSE)  # 1088 m
		# Coarse terrain: a 4 m grid on the same heights, plus skirts hanging SKIRT m below each edge.
		var d: Dictionary = w._build_zone(Vector2i(9, 0), w.Detail.COARSE)
		var verts: PackedVector3Array = d.arrays[Mesh.ARRAY_VERTEX]
		var cn: int = w.ZONE_SIZE / w.COARSE_RES + 1
		assert(verts.size() == cn * cn + 4 * cn)
		assert(d.arrays[Mesh.ARRAY_INDEX].size() == (cn - 1) * (cn - 1) * 6 + 4 * (cn - 1) * 6)
		for k in [0, cn + 3, cn * cn - 1]:
			var v: Vector3 = verts[k] + Vector3(9 * w.ZONE_SIZE, 0, 0)
			assert(is_equal_approx(v.y, w.height(v.x, v.z)), "coarse vertex off the terrain")
		assert(is_equal_approx(verts[cn * cn].y, verts[0].y - w.SKIRT))
		assert(d.rocks.is_empty() and d.flowers.is_empty() and d.map.get_size() == Vector2i(w.MAP_PX, w.MAP_PX))
		trees_before = _tree_count()
		zones_before = w.zones.size()
		_press(KEY_O)  # 1 → 1.5
		_press(KEY_O)  # → 2
		assert(w.density == 2.0)
		assert(w.missing_cells_near(p).size() == zones_before, "every zone should be outdated")
		assert(w.hud.text.contains("×2"))
		phase = 1
	elif phase == 1 and _settled():
		var after := _tree_count()
		print("trees in loaded zones: %d at x1 -> %d at x2 (%d frames to rebuild)" % [trees_before, after, frames - 30])
		assert(after > trees_before * 1.6)
		assert(w.zones.size() == zones_before)
		assert(p.y > w.height(p.x, p.z) - 1.0, "player fell through")
		_press(KEY_P)  # 200 → 300 m
		assert(w.view_dist == 300.0 and w.seasons.env.fog_depth_end == 300.0 and w.player.camera.far == 350.0)
		_press(KEY_P)
		_press(KEY_P)  # → 500 m
		phase = 2
	elif phase == 2 and _settled():
		print("zones: %d at 200 m -> %d at 500 m" % [zones_before, w.zones.size()])
		assert(w.zones.size() > zones_before * 3)
		var light := 0
		for cell in w.built:
			var far: bool = w.dist_to_cell(p, cell) > w.NEAR_DIST + w.ZONE_SIZE * 0.5
			var near: bool = w.dist_to_cell(p, cell) <= w.NEAR_DIST
			if far:
				assert(w.built[cell][1] == w.Detail.LIGHT and not _nodes(cell)[0], "far zone %s should be light" % cell)
				light += 1
				if w.zone_trees[cell].any(func(l): return not l.is_empty()):
					target = cell  # a far zone with trees: walk there next
			elif near:
				assert(w.built[cell][1] == w.Detail.FULL and _nodes(cell)[0], "near zone %s should be full" % cell)
		print("light zones: %d of %d" % [light, w.zones.size()])
		assert(light > w.zones.size() / 2 and target != Vector2i.ZERO)
		assert(not w.is_solid(target))
		# Teleport above it: it becomes full (solid), and the spawn zone, now far behind, goes light.
		var c: Vector3 = Vector3(target.x, 0, target.y) * w.ZONE_SIZE
		w.player.global_position = Vector3(c.x, w.height(c.x, c.z) + 20.0, c.z)
		w.player.velocity = Vector3.ZERO
		phase = 3
	elif phase == 3 and _settled():
		assert(w.is_solid(target) and _nodes(target)[0])
		assert(not w.is_solid(Vector2i.ZERO) and not _nodes(Vector2i.ZERO)[0], "spawn zone should be light now")
		assert(p.y > w.height(p.x, p.z) - 1.0, "player fell through after the teleport")
		print("SETTINGS OK")
		quit()
	elif frames >= 3000:
		print("timeout in phase %d" % phase)
		quit(1)
	return false
