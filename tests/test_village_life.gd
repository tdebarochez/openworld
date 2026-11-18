extends SceneTree
# Run: godot --headless --path . -s tests/test_village_life.gd
# Village life (life.gd, ambience.gd): chimney smoke over a village's full zone; laundry out in fair
# weather but not in winter or rain; windows lit at night, not at noon, and never all of them; flocks
# grazing in open meadows (not in woods, villages, roads or water), deterministic; no village bell;
# water laps near a shore, not inland; the ambient players stay a fixed few.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		if _check():  # a failed assert() returns null from _check without stopping the run
			print("VILLAGE LIFE OK")
			quit()
		else:
			quit(1)
	return false


func _check():
	var life = w.life
	var villages := 0
	var lines := 0
	var forges := 0
	var flocks := 0
	var kinds := {}
	var home := Vector2i(9999, 0)  # a village with a flock
	for gx in range(-6, 6):
		for gz in range(-6, 6):
			var g := Vector2i(gx, gz)
			var v: Dictionary = w.village(g)
			var l: Dictionary = life.village_life(g)
			assert(v.is_empty() == l.is_empty())
			if v.is_empty():
				continue
			villages += 1
			assert(life._village_life(g) == l, "village life not deterministic")
			var roads: Array = w._roads_near(v.centre, 120.0)
			for line in l.laundry:
				lines += 1
				for p in [line[0], line[1], (line[0] + line[1]) / 2.0]:
					assert(not w.in_house(Vector2(p.x, p.z), v.houses, 0.3), "washing line through a house")
					assert(not w._near_line(Vector2(p.x, p.z), roads, w.ROAD_HALF), "washing line on a road")
			if not l.forge.is_empty():
				forges += 1
			if l.flock.is_empty():
				continue
			flocks += 1
			kinds[l.flock.kind] = true
			if home.x == 9999:
				home = g
			for an in l.flock.animals:
				var q := Vector2(an[0].x, an[0].z)
				assert(life.meadow(q, roads), "animal off the meadow")
				assert(w.forest(q.x, q.y) < life.MEADOW_FOREST and w.height(q.x, q.y) > w.WATER_LEVEL + 1.5)
				assert(not w._near_line(q, roads, w.ROAD_HALF + 2.0), "animal on a road")
				for d in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0),
						Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
					var o: Dictionary = w.village(g + d)
					assert(o.is_empty() or o.centre.distance_to(q) >= life.FLOCK_NEAR, "animal in a village")
					assert(o.is_empty() or not w.in_house(q, o.houses, 2.0))
				var cell: Vector2i = w.cell_of(an[0])
				var local: Vector3 = an[0] - Vector3(cell.x, 0, cell.y) * w.ZONE_SIZE
				for list in w.tree_transforms(cell, w.layout(cell).mask):
					for t: Transform3D in list:
						assert(Vector2(t.origin.x, t.origin.z).distance_to(Vector2(local.x, local.z)) > 2.0, "animal in the woods")
	print("%d villages: %d washing lines, %d forges, %d flocks (kinds %s)" % [villages, lines, forges, flocks, kinds.keys()])
	assert(lines > villages and forges > 0 and forges < villages and flocks > villages / 3 and kinds.size() == 2)

	# The flock's village zone: smoke over the chimneys, animals in their own zones (full only).
	var v: Dictionary = w.village(home)
	var hcell: Vector2i = w.cell_of(v.houses[0][0])
	w.add_zone(hcell)
	var smoke := _instances(hcell, life.smoke_mesh)
	var houses: int = v.houses.filter(func(h): return w.cell_of(h[0]) == hcell).size()
	assert(smoke >= houses and houses > 0, "no smoke over the village (%d plumes, %d houses)" % [smoke, houses])
	var fl: Dictionary = life.village_life(home).flock
	var acell: Vector2i = w.cell_of(fl.animals[0][0])
	w.add_zone(acell)
	var owned: int = fl.animals.filter(func(a): return w.cell_of(a[0]) == acell).size()
	assert(_instances(acell, life.animal_meshes[fl.kind]) >= owned, "animals missing from their zone")
	assert(w._build_zone(acell, w.Detail.LIGHT).life.is_empty(), "life in a light zone")
	for m: ArrayMesh in life.animal_meshes:  # grazing reaches the grass
		var g: float = m.surface_get_material(0).get_shader_parameter("graze")
		assert(g > 0.6 and g < 1.6, "graze angle %f" % g)

	# Laundry: out in fair weather, in for rain and all winter; the cloths' shader follows.
	var S = w.seasons.Season
	assert(life.washing_out(S.SUMMER, 0.0) and life.washing_out(S.SPRING, 0.0))
	assert(not life.washing_out(S.WINTER, 0.0) and not life.washing_out(S.SUMMER, 0.5))
	w.seasons.set_season(S.WINTER)
	life._process(0.0)
	assert(life.cloth_mat.get_shader_parameter("shown") == 0.0, "washing out in winter")
	w.seasons.set_season(S.SUMMER)
	life._process(0.0)
	assert(life.cloth_mat.get_shader_parameter("shown") == 1.0)

	# Windows: dark at noon, lit at night, but only some houses (their dice under the share).
	w.daynight.set_time(13.0)
	life._process(0.0)
	assert(life.lit == 0.0 and life.glass_mats.all(func(m): return m.next_pass == null), "windows lit at noon")
	w.daynight.set_time(21.5)
	life._process(0.0)
	assert(life.lit > 0.5 and life.glass_mats.all(func(m): return m.next_pass == life.window_mat), "windows dark at night")
	assert(life.windows_lit(2.0, -0.5, w.LAMP_ON_SUN) < 0.3, "everyone up at 2 am")
	assert(life.window_mat.get_shader_parameter("panes") < 0.7, "every pane of a lit house lit")
	# Smoke follows the sky: dusky at night, not the white ghost trees it was on the web renderer.
	var night_smoke: Vector3 = life.smoke_mat.get_shader_parameter("light")
	w.daynight.set_time(13.0)
	life._process(0.0)
	var day_smoke: Vector3 = life.smoke_mat.get_shader_parameter("light")
	assert(night_smoke.length() < day_smoke.length() * 0.5, "smoke as bright at night %s as by day %s" % [night_smoke, day_smoke])
	w.daynight.set_time(21.5)
	life._process(0.0)
	var on := 0
	var all := 0
	for gx in range(-6, 6):
		for gz in range(-6, 6):
			for hs in w.village(Vector2i(gx, gz)).get("houses", []):
				var d: Color = life.house_dice(Vector3.ZERO, [Transform3D(Basis(), hs[0])] as Array[Transform3D])[0]
				all += 1
				on += int(d.r < life.lit)
	print("windows lit at 21:30: %d / %d houses" % [on, all])
	assert(on > all / 2 and on < all, "all or too few houses lit")

	# Ambience: no village bell (no bell tower yet); lapping near a shore, not inland.
	var amb = w.find_children("", "Node", false, false).filter(func(n): return n.get_script() == preload("res://ambience.gd"))[0]
	var sq := Vector3(v.centre.x, w.height(v.centre.x, v.centre.y) + 1.0, v.centre.y)
	assert(not "bell" in amb, "a bell with no bell tower")
	w.daynight.set_time(10.0)
	var coast := Vector3.INF
	var inland := Vector3.INF
	for x in range(-1500, 1500, 9):
		for z in range(-1500, 1500, 37):
			var h: float = w.height(x, z)
			if coast == Vector3.INF and h > 0.5 and h < 1.5 and w.height(x + 8, z) < -0.5:
				coast = Vector3(x, h + 1.0, z)
			if inland == Vector3.INF and h > 8.0 and amb.shore(Vector3(x, h, z)) == null:
				inland = Vector3(x, h + 1.0, z)
	assert(coast != Vector3.INF and inland != Vector3.INF)
	amb.update(coast)
	assert(amb.water.playing and amb.water.position.distance_to(coast) < amb.SHORE_R + 2.0, "no lapping on the shore")
	amb.update(inland)
	assert(not amb.water.playing, "lapping inland")
	for p in [coast, inland, sq, fl.animals[0][0]]:
		amb.update(p)
		assert(amb.find_children("", "AudioStreamPlayer3D", true, false).size() == amb.POOL, "ambient players not bounded")
	amb.update(fl.animals[0][0])
	assert(amb.flock.playing, "flock silent")
	return true


## Instances of `mesh` in the zone at `cell`.
func _instances(cell: Vector2i, mesh: Mesh) -> int:
	var n := 0
	for c in w.zones[cell].get_children():
		if c is MultiMeshInstance3D and c.multimesh.mesh == mesh:
			n += c.multimesh.instance_count
	return n
