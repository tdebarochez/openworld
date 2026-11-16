extends SceneTree
# Run: godot --headless --path . -s tests/test_world.gd

func _init() -> void:
	var w = preload("res://world.gd").new()
	assert(w.cell_of(Vector3(63.9, 0, 0)) == Vector2i(0, 0))
	assert(w.cell_of(Vector3(64.1, 0, 0)) == Vector2i(1, 0))
	assert(w.cell_of(Vector3(-64.1, 0, -200)) == Vector2i(-1, -2))

	w.add_zone(Vector2i.ZERO)
	w.add_zone(Vector2i(1, 0))
	assert(w.next_free_cell(Vector2i.ZERO, Vector2i(1, 0)) == Vector2i(2, 0))
	assert(w.next_free_cell(Vector2i.ZERO, Vector2i(0, -1)) == Vector2i(0, -1))

	# Seam: zone 0's east edge must equal zone 1's west edge.
	var n: int = w.ZONE_SIZE + 1
	var a: PackedVector3Array = w.zones[Vector2i(0, 0)].get_child(0).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var b: PackedVector3Array = w.zones[Vector2i(1, 0)].get_child(0).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for z in n:
		assert(is_equal_approx(a[z * n + n - 1].y, b[z * n].y))

	# Auto-generation: 50 m from an edge (edge at ±64 → trigger beyond ±14).
	assert(w.cells_near_edges(Vector3(0, 0, 0)).is_empty())
	assert(w.cells_near_edges(Vector3(13, 0, 0)).is_empty())
	assert(w.cells_near_edges(Vector3(20, 0, 0)) == [Vector2i(1, 0)])
	assert(w.cells_near_edges(Vector3(20, 0, -20)) == [Vector2i(1, 0), Vector2i(0, -1), Vector2i(1, -1)])
	assert(w.cells_near_edges(Vector3(128 - 20, 0, 0)) == [Vector2i(0, 0)])

	# Trees: same cell → same trees; none in water; each species appears somewhere nearby.
	var t1: Array = w.tree_transforms(Vector2i(2, -1))
	assert(t1 == w.tree_transforms(Vector2i(2, -1)))
	for list in t1:
		for t in list:
			assert(t.origin.y >= w.WATER_LEVEL + 2.0)
	var counts := [0, 0, 0]
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			var per_kind: Array = w.tree_transforms(Vector2i(cx, cz))
			for k in 3:
				counts[k] += per_kind[k].size()
	print("trees conifer/oak/birch over 25 zones: ", counts)
	assert(counts.min() > 0)

	print("ALL OK")
	w.free()
	quit()
