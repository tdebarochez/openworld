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
	# Flowers: deterministic, each species somewhere within ~1 km, every season has a bloomer.
	assert(w.flower_transforms(Vector2i(2, -1)) == w.flower_transforms(Vector2i(2, -1)))
	var per_flower := []
	per_flower.resize(w.flowers.size())
	per_flower.fill(0)
	for cx in range(-4, 5):
		for cz in range(-4, 5):
			var per_kind: Array = w.flower_transforms(Vector2i(cx, cz))
			for k in per_kind.size():
				per_flower[k] += per_kind[k].size()
				for t in per_kind[k]:
					assert(t.origin.y >= w.WATER_LEVEL + 0.2)
	print("flowers over 81 zones: ", w.flowers.map(func(f): return f.name), " ", per_flower)
	assert(per_flower.min() > 0)
	# Bushes: deterministic, only in the forest-edge band and out of the water, every model used, a
	# higher density keeps density 1's bushes; only full zones get them.
	assert(w.bush_transforms(Vector2i(2, -1)) == w.bush_transforms(Vector2i(2, -1)))
	var per_bush := []
	per_bush.resize(3 * w.BUSH_VARIANTS)
	per_bush.fill(0)
	for cx in range(-3, 3):
		for cz in range(-3, 3):
			var cell := Vector2i(cx, cz)
			var models: Array = w.bush_transforms(cell)
			for m in models.size():
				per_bush[m] += models[m].size()
				for t in models[m]:
					var e: float = w.forest(cx * w.ZONE_SIZE + t.origin.x, cz * w.ZONE_SIZE + t.origin.z)
					assert(e > -w.BUSH_EDGE and e < w.BUSH_EDGE * 0.5, "bush off the forest edge: %f" % e)
					assert(t.origin.y >= w.WATER_LEVEL + 1.0)
			if cx == 0:
				w.density = 2.0
				var dense: Array = w.bush_transforms(cell)
				w.density = 1.0
				for m in models.size():
					for t in models[m]:
						assert(t in dense[m], "density 2 lost a bush")
	print("bushes per model over 36 zones: ", per_bush)
	assert(per_bush.min() > 0)
	var has_bushes := func(cell): return w.zones[cell].get_children().any(func(c): return c.has_meta("bushes"))
	assert(has_bushes.call(Vector2i.ZERO))
	w.add_zone(Vector2i(0, -1), w.Detail.LIGHT)
	assert(not w.bush_transforms(Vector2i(0, -1)).all(func(l): return l.is_empty()))
	assert(not has_bushes.call(Vector2i(0, -1)), "bushes in a light zone")
	var unmasked_blocked := 0  # bushes the roads/villages mask had to remove, within ~1.5 km
	for cx in range(-12, 12):
		for cz in range(-12, 12):
			var cell := Vector2i(cx, cz)
			var mask: PackedByteArray = w.layout(cell).mask
			if not mask.has(w.ROAD) and not mask.has(w.CLEAR):
				continue
			for models in w.bush_transforms(cell, mask):
				for t in models:
					assert(not w._blocked(mask, t.origin.x, t.origin.z), "bush on a road or in a village")
			for models in w.bush_transforms(cell):
				unmasked_blocked += models.filter(func(t): return w._blocked(mask, t.origin.x, t.origin.z)).size()
	assert(unmasked_blocked > 0, "no road crosses a forest edge: the mask check above tested nothing")
	# Villages and roads: some exist within 2 km, roads are symmetric and cross no water,
	# houses sit off the roads and away from each other, and the layout clears trees there.
	var villages := 0
	var roads := 0
	var lamps := 0
	var kinds := {}
	var houses := 0
	var odd := 0  # houses not of their village's main style
	for gx in range(-5, 5):
		for gz in range(-5, 5):
			var g := Vector2i(gx, gz)
			var v: Dictionary = w.village(g)
			if not v.is_empty():
				villages += 1
				# The web renderer lights each object (a zone's terrain holds a whole village) with at most
				# this many lights; past it, some lamps would neither light nor shade the ground.
				assert(v.lamps.size() <= ProjectSettings.get_setting("rendering/limits/opengl/max_lights_per_object"))
				for lamp in v.lamps:
					var lp: Vector3 = lamp[0]
					lamps += 1
					# The arm (+X after the lamp's yaw) reaches towards the square.
					var arm: Vector3 = Basis(Vector3.UP, lamp[1]) * Vector3.RIGHT
					assert(Vector2(arm.x, arm.z).dot((v.centre - Vector2(lp.x, lp.z)).normalized()) > 0.99)
					for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						assert(not w._near_line(Vector2(lp.x, lp.z), [w.road(g, g + d)], w.ROAD_HALF + 0.5), "lamp on a road")
					# Outside every house's walls, balcony and porch (everything lower than the lantern).
					assert(not w.in_house(Vector2(lp.x, lp.z), v.houses, 0.3), "lamp in a house")
				var styles := [0, 0]
				for i in v.houses.size():
					var hs: Array = v.houses[i]
					var p := Vector2(hs[0].x, hs[0].z)
					var rad: float = w.house_radius[hs[2]]
					kinds[hs[2]] = true
					styles[hs[2] / w.HOUSE_VARIANTS] += 1
					assert(hs[0].y > w.WATER_LEVEL)
					for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						assert(not w._near_line(p, [w.road(g, g + d)], rad + w.ROAD_HALF), "house on a road")
					assert(p.distance_to(v.centre) > rad + 8.3, "house over the square's lamps")
					for j in i:  # roofs never touch, whatever the yaws
						var o: Array = v.houses[j]
						assert(p.distance_to(Vector2(o[0].x, o[0].z)) >= rad + w.house_radius[o[2]], "houses overlap")
				odd += styles.min()
				houses += v.houses.size()
			for d in [Vector2i(1, 0), Vector2i(0, 1)]:
				var r: PackedVector2Array = w.road(g, g + d)
				assert(r == w.road(g + d, g))
				if not r.is_empty():
					roads += 1
					for p in r:
						assert(w.height(p.x, p.y) >= w.WATER_LEVEL + 0.5)
	print("villages %d, roads %d, street lamps %d, houses %d (%d off their village's style), kinds %s over 4 x 4 km" % [villages, roads, lamps, houses, odd, kinds.keys()])
	assert(villages > 0 and roads > 0 and lamps > villages * 5)
	assert(kinds.size() == w.HOUSE_KINDS, "every house kind is used")
	assert(odd < houses * 0.2, "villages should keep mostly one style")
	for k in w.HOUSE_KINDS:  # the collision box sits within the house, the lamps' keep-out area covers it
		var hb := AABB(w.house_centres[k] - w.house_shapes[k].size / 2.0, w.house_shapes[k].size)
		assert(w.house_low[k].encloses(Rect2(hb.position.x, hb.position.z, hb.size.x, hb.size.z)))
		assert(hb.size.x > 4.0 and hb.size.z > 4.0 and hb.position.y == 0.0 and w.house_radius[k] < 9.0)
		print("house %d: walls %s, low %s, radius %.1f" % [k, hb, w.house_low[k], w.house_radius[k]])
	for gx in range(-3, 3):  # a zone with a house: no tree within the house's clearing
		var v: Dictionary = w.village(Vector2i(gx, 0))
		if v.is_empty() or v.houses.is_empty():
			continue
		var hp: Vector3 = v.houses[0][0]
		var cell: Vector2i = w.cell_of(hp)
		var lay: Dictionary = w.layout(cell)
		var local: Vector2 = Vector2(hp.x, hp.z) - Vector2(cell) * w.ZONE_SIZE
		for models in w.tree_transforms(cell, lay.mask):
			for t in models:
				assert(Vector2(t.origin.x, t.origin.z).distance_to(local) > w.house_radius[v.houses[0][2]], "tree inside a house")
		assert(lay.houses.any(func(l): return not l.is_empty()))
		assert(not lay.lamps.is_empty(), "no street lamp in a village zone")
		break
	# Benches, planters and village flowers: deterministic, off the roads, out of the houses, clear of
	# the lamps and of each other; benches face the square, planters stand against a front wall; a
	# village zone's layout and full build carry them.
	var benches := 0
	var planters := 0
	var plants := 0
	var garden: Array = w.VILLAGE_FLOWERS.map(func(n): return w.flowers.find_custom(func(f): return f.name == n))
	var spawn_village: Vector2i
	for gx in range(-5, 5):
		for gz in range(-5, 5):
			var g := Vector2i(gx, gz)
			var v: Dictionary = w.village(g)
			if v.is_empty():
				continue
			if v.centre.distance_to(Vector2(133.7, -143.1)) < 5.0:
				spawn_village = g
			var again: Dictionary = w._village(g)
			assert(again.props == v.props and again.flowers == v.flowers)
			var near_roads := []
			for d in w.LINK_OFFSETS:
				near_roads.append(w.road(g, g + d))
			var bench_list: Array = v.props.filter(func(o): return o[2] != w.Prop.PLANTER)
			for pr in v.props:
				var p := Vector2(pr[0].x, pr[0].z)
				var planter: bool = pr[2] == w.Prop.PLANTER
				assert(not w._near_line(p, near_roads, w.ROAD_HALF + 0.8), "bench or planter on a road")
				assert(not w.in_house(p, v.houses, 0.1 if planter else 0.8), "bench or planter in a house")
				assert(w.in_house(p, v.houses, 0.6) == planter, "planter off a house front")
				assert(w._far_from(p, v.lamps, 0.9 if planter else 1.2), "bench or planter against a lamp")
				assert(w._far_from(p, v.props.filter(func(o): return o != pr), 0.9 if planter else 1.8), "props overlap")
				if not planter:
					var front: Vector3 = Basis(Vector3.UP, pr[1]) * Vector3.BACK
					assert(Vector2(front.x, front.z).dot((v.centre - p).normalized()) > 0.99, "bench not facing the square")
			benches += bench_list.size()
			planters += v.props.size() - bench_list.size()
			for i in v.flowers.size():
				var f: Array = v.flowers[i]
				var p := Vector2(f[0].x, f[0].z)
				assert(f[2] in garden)
				assert(not w._near_line(p, near_roads, w.ROAD_HALF + 0.3), "flower on a road")
				assert(not w.in_house(p, v.houses, 0.1), "flower in a house")
				assert(w._far_from(p, v.lamps, 0.5) and w._far_from(p, bench_list, 0.9), "flower against a lamp or bench")
				for j in i:
					assert(p.distance_to(Vector2(v.flowers[j][0].x, v.flowers[j][0].z)) > 0.1, "flowers overlap")
			plants += v.flowers.size()
	print("benches %d, planters %d, village flowers %d over %d villages" % [benches, planters, plants, villages])
	assert(benches >= villages * 2 and planters >= villages * 4 and plants >= villages * 40)
	var sv: Dictionary = w.village(spawn_village)
	print("spawn village: %d houses, %d lamps, %d props, %d flowers" % [sv.houses.size(), sv.lamps.size(), sv.props.size(), sv.flowers.size()])
	var vcell: Vector2i = w.cell_of(sv.props[0][0])
	var vlay: Dictionary = w.layout(vcell)
	assert(not vlay.props[w.Prop.PLANTER].is_empty() and not (vlay.props[0] + vlay.props[1]).is_empty(), "no bench or planter in a village zone")
	assert(vlay.flowers.any(func(l): return not l.is_empty()), "no flower in a village zone")
	var wild: Array = w.flower_transforms(vcell, vlay.mask)
	var full: Dictionary = w._build_zone(vcell)
	for k in wild.size():
		assert(full.flowers[k].size() == wild[k].size() + vlay.flowers[k].size())
	assert(w._build_zone(vcell, w.Detail.LIGHT).props.is_empty())
	for season in ["summer", "autumn", "winter", "spring"]:
		assert(w.flowers.any(func(f): return season in f.bloom), "nothing blooms in " + season)
	assert(rocks_plain + rocks_hill > 0)

	print("ALL OK")
	w.free()
	quit()
