extends SceneTree
# Run: godot --headless --path . -s tests/test_world.gd

func _init() -> void:
	var w = preload("res://world.gd").new()
	assert(w.cell_of(Vector3(63.9, 0, 0)) == Vector2i(0, 0))
	assert(w.cell_of(Vector3(64.1, 0, 0)) == Vector2i(1, 0))
	assert(w.cell_of(Vector3(-64.1, 0, -200)) == Vector2i(-1, -2))

	w.add_zone(Vector2i.ZERO)
	w.add_zone(Vector2i(1, 0))

	# Seam: zone 0's east edge must equal zone 1's west edge.
	var n: int = w.ZONE_SIZE + 1
	var a: PackedVector3Array = w.zones[Vector2i(0, 0)].get_child(0).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = w.zones[Vector2i(1, 0)].get_child(0).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for z in n:
		assert(is_equal_approx(a[z * n + n - 1].y, b[z * n].y))

	# Auto-generation within 200 m (zones (0,0) and (1,0) exist).
	assert(w.dist_to_cell(Vector3(10, 0, 10), Vector2i.ZERO) == 0.0)
	assert(is_equal_approx(w.dist_to_cell(Vector3.ZERO, Vector2i(2, 0)), 192.0))
	var todo: Array[Vector2i] = w.missing_cells_near(Vector3.ZERO)
	assert(not todo.has(Vector2i(0, 0)) and not todo.has(Vector2i(1, 0)))
	assert(todo.has(Vector2i(2, 0)))       # edge at 192 m
	assert(not todo.has(Vector2i(2, 1)))   # corner at ~202 m
	assert(not todo.has(Vector2i(3, 0)))   # edge at 320 m
	assert(is_equal_approx(w.dist_to_cell(Vector3.ZERO, todo[0]), 64.0))  # nearest first
	print("zones to generate around origin: ", todo.size() + 2)

	# Trees: same cell → same trees; none in water; each species appears somewhere nearby.
	var t1: Array = w.tree_transforms(Vector2i(2, -1))
	assert(t1 == w.tree_transforms(Vector2i(2, -1)))
	for list in t1:
		for t in list:
			assert(t.origin.y >= w.WATER_LEVEL + 2.0)
	var counts := [0, 0, 0]
	var per_model := []
	per_model.resize(3 * w.TREE_VARIANTS)
	per_model.fill(0)
	var rocks_plain := 0
	var rocks_hill := 0
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var cell := Vector2i(cx, cz)
			var models: Array = w.tree_transforms(cell)
			for m in models.size():
				counts[m / w.TREE_VARIANTS] += models[m].size()
				per_model[m] += models[m].size()
			var hilly: bool = w.hilliness(cx * w.ZONE_SIZE, cz * w.ZONE_SIZE) > 0.5
			for list in w.rock_transforms(cell):
				for t in list:
					assert(t.origin.y >= w.WATER_LEVEL + 0.3)
					if hilly: rocks_hill += 1
					else: rocks_plain += 1
	print("trees conifer/oak/birch over 25 zones: ", counts, "  per variant: ", per_model)
	assert(counts.min() > 0)
	assert(per_model.min() > 0)  # every variant of every species is used
	assert(w.rock_transforms(Vector2i(2, -1)) == w.rock_transforms(Vector2i(2, -1)))
	print("rocks over 25 zones: plains-centred ", rocks_plain, ", hill-centred ", rocks_hill)
	assert(rocks_plain + rocks_hill > 0)

	print("ALL OK")
	w.free()
	quit()
