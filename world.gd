extends Node3D
## Open world made of square terrain zones, streamed in around the player (built on worker threads).
## Heights come from one global noise field, so adjacent zones always join seamlessly.

const ZONE_SIZE := 128  # metres per side; 1 m grid so HeightMapShape3D needs no scaling
const WATER_LEVEL := 0.0
const VIEW_DIST := 200.0  # zones closer than this get generated; fog is fully opaque here
const TREE_ATTEMPTS := 400  # random spots tried per zone; most are rejected (water, slope, clearing)
const MAX_JOBS := 4  # zones built in parallel on worker threads
enum TreeKind { CONIFER, OAK, BIRCH }

var zones := {}  # Vector2i -> Node3D
var jobs := {}  # Vector2i -> {task: int, data: Dictionary} for zones being built on a worker thread
var threaded := OS.has_feature("threads")  # false in the web export (no-threads build)
var noise := FastNoiseLite.new()
var terrain_mat := StandardMaterial3D.new()
var water_mat := StandardMaterial3D.new()
var species := []  # indexed by TreeKind: list of [mesh, lift] parts, meshes are centred so lift = centre height
var trunk_shape := CylinderShape3D.new()
var player: CharacterBody3D
var hud := Label.new()


func _init() -> void:
	noise.seed = 1337
	noise.frequency = 0.004
	noise.fractal_octaves = 5
	terrain_mat.vertex_color_use_as_albedo = true
	terrain_mat.vertex_color_is_srgb = true  # colors below are picked in sRGB
	water_mat.albedo_color = Color(0.15, 0.4, 0.6, 0.75)
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_mat.roughness = 0.05
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.6
	cone.height = 4.0
	var oak_crown := SphereMesh.new()  # wide, flattened
	oak_crown.radius = 2.6
	oak_crown.height = 4.0
	var birch_crown := SphereMesh.new()  # narrow, elongated
	birch_crown.radius = 1.2
	birch_crown.height = 3.6
	species.resize(TreeKind.size())
	species[TreeKind.CONIFER] = _tree_parts(0.15, 0.25, 2.0, Color(0.4, 0.27, 0.15), cone, 4.0, Color(0.13, 0.36, 0.15))
	species[TreeKind.OAK] = _tree_parts(0.3, 0.45, 3.0, Color(0.33, 0.24, 0.15), oak_crown, 4.6, Color(0.24, 0.42, 0.12))
	species[TreeKind.BIRCH] = _tree_parts(0.09, 0.13, 5.0, Color(0.88, 0.87, 0.82), birch_crown, 5.6, Color(0.5, 0.68, 0.22))
	trunk_shape.radius = 0.3
	trunk_shape.height = 2.0


func _tree_parts(top_r: float, bottom_r: float, trunk_h: float, bark: Color, crown: PrimitiveMesh, crown_y: float, leaves: Color) -> Array:
	var trunk := CylinderMesh.new()
	trunk.top_radius = top_r
	trunk.bottom_radius = bottom_r
	trunk.height = trunk_h
	trunk.material = StandardMaterial3D.new()
	trunk.material.albedo_color = bark
	crown.material = StandardMaterial3D.new()
	crown.material.albedo_color = leaves
	return [[trunk, trunk_h / 2.0], [crown, crown_y]]


func _ready() -> void:
	_setup_environment()
	for c in missing_cells_near(Vector3.ZERO):  # whole view up front (~40 ms per zone)
		add_zone(c)
	player = preload("res://player.gd").new()
	player.world = self
	add_child(player)
	player.position = Vector3(0, maxf(height(0, 0), WATER_LEVEL) + 2.0, 0)
	var layer := CanvasLayer.new()
	hud.position = Vector2(12, 12)
	layer.add_child(hud)
	add_child(layer)
	_update_hud()


func height(x: float, z: float) -> float:
	return noise.get_noise_2d(x, z) * 35.0 + 5.0


## Normal from the global field (not the mesh) so lighting matches across zone edges.
func _normal(x: float, z: float) -> Vector3:
	return Vector3(height(x - 1, z) - height(x + 1, z), 2.0, height(x, z - 1) - height(x, z + 1)).normalized()


## Tree placements in zone-local coords (origin on the ground), deterministic per seed + cell.
## Returns one Array[Transform3D] per TreeKind.
func tree_transforms(cell: Vector2i) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(noise.seed, cell.x, cell.y))
	var half := ZONE_SIZE / 2.0
	var out := []
	for k in TreeKind.size():
		out.append([] as Array[Transform3D])
	for i in TREE_ATTEMPTS:
		# Draw every value up front so the sequence never depends on which spots get rejected.
		var lx := rng.randf_range(-half, half)
		var lz := rng.randf_range(-half, half)
		var s := rng.randf_range(0.7, 1.4)
		var rot := rng.randf() * TAU
		var wx := cell.x * ZONE_SIZE + lx
		var wz := cell.y * ZONE_SIZE + lz
		var h := height(wx, wz)
		if h < WATER_LEVEL + 2.0 or h > 20.0 or _normal(wx, wz).y < 0.85:
			continue
		if noise.get_noise_2d(wx * 4.0 + 5000.0, wz * 4.0) < 0.0:  # forests vs clearings
			continue
		# Species in groves: conifers up high, oak/birch patches below.
		var v := noise.get_noise_2d(wx * 2.0 - 7000.0, wz * 2.0)
		var kind := TreeKind.CONIFER if h > 14.0 or v < -0.1 else (TreeKind.OAK if v < 0.1 else TreeKind.BIRCH)
		out[kind].append(Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * s), Vector3(lx, h, lz)))
	return out


func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(floori((p.x + ZONE_SIZE / 2.0) / ZONE_SIZE), floori((p.z + ZONE_SIZE / 2.0) / ZONE_SIZE))


## Horizontal distance from `p` to the nearest point of a cell's square (0 when inside).
func dist_to_cell(p: Vector3, cell: Vector2i) -> float:
	var d := (Vector2(p.x, p.z) - Vector2(cell) * ZONE_SIZE).abs() - Vector2.ONE * (ZONE_SIZE / 2.0)
	return d.max(Vector2.ZERO).length()


## Not-yet-generated cells within VIEW_DIST of `p`, nearest first.
func missing_cells_near(p: Vector3) -> Array[Vector2i]:
	var c := cell_of(p)
	var r := ceili(VIEW_DIST / ZONE_SIZE) + 1
	var out: Array[Vector2i] = []
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var cell := c + Vector2i(dx, dz)
			if not zones.has(cell) and not jobs.has(cell) and dist_to_cell(p, cell) <= VIEW_DIST:
				out.append(cell)
	out.sort_custom(func(a, b): return dist_to_cell(p, a) < dist_to_cell(p, b))
	return out


func _physics_process(_delta: float) -> void:
	# Attach zones whose worker finished (node creation must happen on the main thread).
	for cell in jobs.keys():
		var job: Dictionary = jobs[cell]
		if WorkerThreadPool.is_task_completed(job.task):
			WorkerThreadPool.wait_for_task_completion(job.task)
			jobs.erase(cell)
			_attach_zone(job.data)
			_update_hud()
	# Start building the nearest missing zones.
	for cell in missing_cells_near(player.global_position):
		if not threaded:  # no threads (web): one synchronous zone per frame
			add_zone(cell)
			_update_hud()
			break
		if jobs.size() >= MAX_JOBS:
			break
		var job := {"task": -1, "data": {}}
		job.task = WorkerThreadPool.add_task(func(): job.data = _build_zone(cell))
		jobs[cell] = job


func _exit_tree() -> void:
	for job in jobs.values():
		WorkerThreadPool.wait_for_task_completion(job.task)


## Synchronous build + attach (startup and tests).
func add_zone(cell: Vector2i) -> void:
	if not zones.has(cell):
		_attach_zone(_build_zone(cell))


## Heavy part, thread-safe: only reads the noise and returns plain data.
func _build_zone(cell: Vector2i) -> Dictionary:
	var origin := Vector2(cell) * ZONE_SIZE
	var n := ZONE_SIZE + 1
	var half := ZONE_SIZE / 2
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var heights := PackedFloat32Array()
	var min_h := INF
	for z in n:
		for x in n:
			var wx := origin.x + x - half
			var wz := origin.y + z - half
			var h := height(wx, wz)
			var nrm := _normal(wx, wz)
			verts.append(Vector3(x - half, h, z - half))
			normals.append(nrm)
			colors.append(_ground_color(h, nrm.y))
			heights.append(h)
			min_h = minf(min_h, h)

	var idx := PackedInt32Array()
	for z in ZONE_SIZE:
		for x in ZONE_SIZE:
			var i := z * n + x
			idx.append_array([i, i + 1, i + n, i + 1, i + n + 1, i + n])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	return {"cell": cell, "arrays": arrays, "heights": heights, "min_h": min_h, "trees": tree_transforms(cell)}


## Light part, main thread: turn built data into nodes.
func _attach_zone(d: Dictionary) -> void:
	var cell: Vector2i = d.cell
	var n := ZONE_SIZE + 1
	var zone := Node3D.new()
	zone.name = "Zone_%d_%d" % [cell.x, cell.y]
	zone.position = Vector3(cell.x, 0, cell.y) * ZONE_SIZE
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, d.arrays)
	mesh.surface_set_material(0, terrain_mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	zone.add_child(mi)

	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = d.heights
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.add_child(cs)
	zone.add_child(body)

	var all_trees: Array = d.trees
	for kind in all_trees.size():
		var trees: Array[Transform3D] = all_trees[kind]
		if trees.is_empty():
			continue
		for part in species[kind]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = part[0]
			mm.instance_count = trees.size()
			for i in trees.size():
				mm.set_instance_transform(i, trees[i].translated_local(Vector3(0, part[1], 0)))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			zone.add_child(mmi)
		for t in trees:  # trunk collision only; crowns are above head height
			var tcs := CollisionShape3D.new()
			tcs.shape = trunk_shape
			tcs.position = t.origin + Vector3.UP
			body.add_child(tcs)

	if d.min_h < WATER_LEVEL:
		var plane := PlaneMesh.new()
		plane.size = Vector2(ZONE_SIZE, ZONE_SIZE)
		plane.material = water_mat
		var water := MeshInstance3D.new()
		water.mesh = plane
		water.position.y = WATER_LEVEL
		zone.add_child(water)

	zones[cell] = zone
	add_child(zone)


func _ground_color(h: float, up: float) -> Color:
	if h < WATER_LEVEL + 1.5:
		return Color(0.76, 0.7, 0.5)  # sand / lakebed
	if up < 0.8:
		return Color(0.45, 0.42, 0.4)  # steep = rock
	if h > 22.0:
		return Color(0.92, 0.92, 0.95)  # peaks
	return Color(0.3, 0.55, 0.2)  # grass


func _update_hud() -> void:
	hud.text = "ZQSD/WASD bouger · Shift courir · Espace sauter/remonter · Souris regarder · Échap souris\nZones : %d" % zones.size()


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	# Haze = sky horizon colour; the ground half of the sky matches it so nothing shows past the fog.
	var haze := sky_mat.sky_horizon_color
	sky_mat.ground_horizon_color = haze
	sky_mat.ground_bottom_color = haze
	env.sky.sky_material = sky_mat
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = 1.0  # depth mode: opacity reached at fog_depth_end
	env.fog_light_color = haze
	env.fog_depth_begin = VIEW_DIST * 0.4
	env.fog_depth_end = VIEW_DIST
	env.fog_sky_affect = 0.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		# Web/WebGL2 renderer over-brightens ambient and sky reflections; use a dim flat ambient.
		# ponytail: hand-tuned against Forward+ screenshots, retune if lighting changes.
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.65, 0.75, 0.9)
		env.ambient_light_energy = 0.1
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
