extends Node3D
## Open world made of square terrain zones, streamed in around the player (built on worker threads).
## Heights come from one global noise field, so adjacent zones always join seamlessly.

const ZONE_SIZE := 128  # metres per side; 1 m grid so HeightMapShape3D needs no scaling
const WATER_LEVEL := 0.0
const VIEW_DIST := 200.0  # zones closer than this get generated; fog is fully opaque here
const TREE_ATTEMPTS := 400  # random spots tried per zone; most are rejected (water, slope, clearing)
const TREE_VARIANTS := 3  # models per species (tools/make_trees.py)
const ROCK_ATTEMPTS := 40  # ~6 rocks per zone on plains, ~30 in hills
const ROCK_KINDS := 5  # tools/make_rocks.py; rock_3 is a pebble (no collision)
const FLOWER_CLUSTERS := 40  # flower beds tried per zone; about half fit their species' habitat
const VILLAGE_GRID := 400.0  # one candidate village per 400 m square, kept only on flat plains
const HOUSE_KINDS := 3  # tools/make_houses.py
const ROAD_HALF := 2.0  # road half-width, metres
const ROAD_LINKS := 2  # each village gets a road to its nearest villages…
const ROAD_MAX := 900.0  # …within this distance
const LINK_OFFSETS: Array[Vector2i] = [  # squares searched for neighbours (5x5 minus the centre)
	Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2), Vector2i(1, -2), Vector2i(2, -2),
	Vector2i(-2, -1), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(2, -1),
	Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(2, 0),
	Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
	Vector2i(-2, 2), Vector2i(-1, 2), Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2)]
const ROAD_COLOR := Color(0.55, 0.45, 0.32)  # dirt; seasons.gd recolours it (5th ground key)
enum { FREE, CLEAR, ROAD }  # layout mask: CLEAR = no trees/rocks/flowers, ROAD = dirt surface too
const MAX_JOBS := 4  # zones built in parallel on worker threads
const MAP_PX := 32  # map pixels per zone side (4 m per pixel)
enum TreeKind { CONIFER, OAK, BIRCH }

var zones := {}  # Vector2i -> Node3D
var zone_trees := {}  # Vector2i -> the zone's `trees` data (zone-local, per model); birds.gd perches on them
var map_tiles := {}  # Vector2i -> Image, top-down view of each generated zone
var jobs := {}  # Vector2i -> {task: int, data: Dictionary} for zones being built on a worker thread
var threaded := OS.has_feature("threads")  # false in the web export (no-threads build)
var noise := FastNoiseLite.new()
var seasons := preload("res://seasons.gd").new()
var terrain_mat: ShaderMaterial = seasons.terrain_mat  # recolours the vertex colours per season
var daynight  # daynight.gd, made in _ready
var water_mat := StandardMaterial3D.new()
var species: Array[Mesh] = []  # indexed by kind * TREE_VARIANTS + variant
var trunk_shape := CylinderShape3D.new()
var rock_meshes: Array[Mesh] = []
var rock_shapes: Array[Shape3D] = []  # convex hull per rock kind, null for the pebble
# From assets/flowers/flowers.json (tools/make_flowers.py): name, bloom (season names), habitat, …
# plus "mesh". Surface 0 = foliage, surfaces ≥ 1 = blossom (seasons.gd hides them out of season).
var flowers: Array = []
var house_meshes: Array[Mesh] = []
var house_shapes: Array[BoxShape3D] = []  # per kind, the walls' box (plinth excluded)
var house_centres: Array[Vector3] = []  # per kind, centre of that box in the house's frame
# Memoised village sites / villages / roads (pure functions of the seed), shared by worker threads.
var _sites := {}
var _villages := {}
var _roads := {}
var _memo_lock := Mutex.new()
var player: CharacterBody3D
var hud := Label.new()


func _init() -> void:
	noise.seed = 1337
	noise.frequency = 0.004
	noise.fractal_octaves = 5
	seasons.world = self
	add_child(seasons)
	water_mat.albedo_color = Color(0.15, 0.4, 0.6, 0.75)
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_mat.roughness = 0.05
	# Models from tools/make_trees.py and tools/make_rocks.py (Blender), base at origin.
	for file in ["conifer", "oak", "birch"]:  # TreeKind order
		for v in TREE_VARIANTS:
			species.append(_tintable_leaves(_load_mesh("res://assets/trees/%s_%d.glb" % [file, v])))
	for r in ROCK_KINDS:
		var m := _load_mesh("res://assets/rocks/rock_%d.glb" % r)
		rock_meshes.append(m)
		rock_shapes.append(null if r == 3 else m.create_convex_shape())
	flowers = JSON.parse_string(FileAccess.get_file_as_string("res://assets/flowers/flowers.json"))
	for f: Dictionary in flowers:
		f.mesh = _load_mesh("res://assets/flowers/" + f.file)
	for k in HOUSE_KINDS:
		var m := _load_mesh("res://assets/houses/house_%d.glb" % k)
		house_meshes.append(m)
		var box := m.get_aabb()
		box = box.intersection(AABB(Vector3(box.position.x, 0, box.position.z), Vector3(box.size.x, box.end.y, box.size.z)))
		var shape := BoxShape3D.new()
		shape.size = box.size
		house_shapes.append(shape)
		house_centres.append(box.get_center())
	trunk_shape.radius = 0.3
	trunk_shape.height = 2.0


func _load_mesh(path: String) -> ArrayMesh:
	var scene: Node = load(path).instantiate()
	var mesh := (scene.find_children("", "MeshInstance3D")[0] as MeshInstance3D).mesh as ArrayMesh
	scene.free()
	return mesh


func _ready() -> void:
	_setup_environment()
	for c in missing_cells_near(Vector3.ZERO):  # whole view up front (~40 ms per zone)
		add_zone(c)
	player = preload("res://player.gd").new()
	player.world = self
	add_child(player)
	player.position = Vector3(0, maxf(height(0, 0), WATER_LEVEL) + 2.0, 0)
	seasons.setup()
	daynight = preload("res://daynight.gd").new()
	daynight.world = self
	add_child(daynight)  # after seasons.setup(): applies its light for the hour
	add_child(preload("res://birds.gd").new())  # finds the world as its parent
	add_child(preload("res://clouds.gd").new())  # same
	var layer := CanvasLayer.new()
	var map := preload("res://map.gd").new()
	map.world = self
	layer.add_child(map)
	hud.position = Vector2(12, 12)
	layer.add_child(hud)
	add_child(layer)
	_update_hud()


func height(x: float, z: float) -> float:
	var n := noise.get_noise_2d(x, z)
	return lerpf(n * 6.0 + 4.0, n * 35.0 + 5.0, hilliness(x, z))  # plains (1..7 m) → hills (±20 m)


## 0 = plain, 1 = hills. Very low frequency (regions of ~1 km), sampled far from the height noise.
func hilliness(x: float, z: float) -> float:
	return smoothstep(-0.15, 0.15, noise.get_noise_2d(x * 0.3 + 20000.0, z * 0.3))


## Normal from the global field (not the mesh) so lighting matches across zone edges.
func _normal(x: float, z: float) -> Vector3:
	return Vector3(height(x - 1, z) - height(x + 1, z), 2.0, height(x, z - 1) - height(x, z + 1)).normalized()


## Tree placements in zone-local coords (origin on the ground), deterministic per seed + cell.
## Returns one Array[Transform3D] per TreeKind.
func tree_transforms(cell: Vector2i, mask := PackedByteArray()) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(noise.seed, cell.x, cell.y))
	var half := ZONE_SIZE / 2.0
	var out := []
	for k in TreeKind.size() * TREE_VARIANTS:
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
		if h < WATER_LEVEL + 2.0 or h > 20.0 or _normal(wx, wz).y < 0.85 or _blocked(mask, lx, lz):
			continue
		if noise.get_noise_2d(wx * 4.0 + 5000.0, wz * 4.0) < 0.0:  # forests vs clearings
			continue
		# Species in groves: conifers up high, oak/birch patches below.
		var v := noise.get_noise_2d(wx * 2.0 - 7000.0, wz * 2.0)
		var kind := TreeKind.CONIFER if h > 14.0 or v < -0.1 else (TreeKind.OAK if v < 0.1 else TreeKind.BIRCH)
		# Variant from position, not the RNG, so adding variants never moved existing trees.
		var variant := hash(Vector3i(roundi(wx * 10.0), roundi(wz * 10.0), 7)) % TREE_VARIANTS
		out[kind * TREE_VARIANTS + variant].append(Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * s), Vector3(lx, h, lz)))
	return out


## Rock placements per rock kind (zone-local, origin on the ground, tilted to the slope).
## Deterministic per seed + cell; denser in hills than on plains.
## Flower placements per flower kind (zone-local), grouped in beds of one species (6-20 plants
## within a few metres), each bed in its species' habitat. Deterministic per seed + cell.
func flower_transforms(cell: Vector2i, mask := PackedByteArray()) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(noise.seed + 2, cell.x, cell.y))
	var half := ZONE_SIZE / 2.0
	var out := []
	for k in flowers.size():
		out.append([] as Array[Transform3D])
	for c in FLOWER_CLUSTERS:
		var cx := rng.randf_range(-half, half)
		var cz := rng.randf_range(-half, half)
		var kind := rng.randi() % flowers.size()
		var count := rng.randi_range(6, 20)
		var spots := []  # drawn even if the bed is rejected, so the RNG sequence stays fixed
		for i in count:
			spots.append([rng.randfn(0.0, 1.8), rng.randfn(0.0, 1.8), rng.randf_range(0.8, 1.3), rng.randf() * TAU])
		var h0 := height(cell.x * ZONE_SIZE + cx, cell.y * ZONE_SIZE + cz)
		var hill := hilliness(cell.x * ZONE_SIZE + cx, cell.y * ZONE_SIZE + cz)
		var ok: bool
		match flowers[kind].habitat:
			"plain": ok = hill < 0.5
			"hills": ok = hill > 0.5
			"near_water": ok = h0 < WATER_LEVEL + 3.0
			_: ok = true
		if not ok:
			continue
		for sp in spots:
			var lx := clampf(cx + sp[0], -half, half - 0.01)
			var lz := clampf(cz + sp[1], -half, half - 0.01)
			var wx := cell.x * ZONE_SIZE + lx
			var wz := cell.y * ZONE_SIZE + lz
			var h := height(wx, wz)
			if h < WATER_LEVEL + 0.2 or _normal(wx, wz).y < 0.8 or _blocked(mask, lx, lz):
				continue
			var s: float = sp[2] * (1.6 if flowers[kind].name == "snowdrop" else 1.0)  # true size vanishes
			out[kind].append(Transform3D(Basis(Vector3.UP, sp[3]).scaled(Vector3.ONE * s), Vector3(lx, h, lz)))
	return out


## Centre of the village in the VILLAGE_GRID square `g`, or {} when its spot isn't a dry flat plain
## (or the dice say no). Pure function of the seed: every zone computes the same villages and roads.
func village_site(g: Vector2i) -> Dictionary:
	return _memo(_sites, g, _village_site.bind(g))


func _village_site(g: Vector2i) -> Dictionary:
	var h := hash(Vector3i(noise.seed + 3, g.x, g.y))
	if h % 10 >= 7:
		return {}
	var c := (Vector2(g) + Vector2(0.25 + 0.5 * float((h >> 8) & 0xFF) / 255.0,
		0.25 + 0.5 * float((h >> 16) & 0xFF) / 255.0)) * VILLAGE_GRID
	if hilliness(c.x, c.y) > 0.2 or height(c.x, c.y) < WATER_LEVEL + 1.5 or _normal(c.x, c.y).y < 0.95:
		return {}
	return {"centre": c, "seed": h}


## Village site plus its houses, placed around the square and kept off the village's roads.
func village(g: Vector2i) -> Dictionary:
	return _memo(_villages, g, _village.bind(g))


func _village(g: Vector2i) -> Dictionary:
	var site := village_site(g)
	if site.is_empty():
		return {}
	var c: Vector2 = site.centre
	var roads := []
	for d in LINK_OFFSETS:
		roads.append(road(g, g + d))
	var rng := RandomNumberGenerator.new()
	rng.seed = site.seed
	var houses := []  # [world position, yaw, kind]; doors (+Z) face the village square
	var count := rng.randi_range(4, 9)
	for i in count:
		var a := TAU * i / count + rng.randf_range(-0.25, 0.25)
		var r := rng.randf_range(13.0, 24.0)
		var kind := rng.randi() % HOUSE_KINDS
		var p := c + Vector2(cos(a), sin(a)) * r
		var ph := height(p.x, p.y)
		if ph < WATER_LEVEL + 1.0 or _normal(p.x, p.y).y < 0.9 or _near_line(p, roads, 8.0) \
				or houses.any(func(o): return Vector2(o[0].x, o[0].z).distance_to(p) < 11.0):
			continue
		var to_square := c - p
		houses.append([Vector3(p.x, ph - 0.1, p.y), atan2(to_square.x, to_square.y), kind])
	return {"centre": c, "houses": houses}


## table[key], computing it with `fn` on first use. Thread-safe; two threads may compute the same
## entry concurrently, which is harmless since `fn` is pure.
func _memo(table: Dictionary, key: Variant, fn: Callable) -> Variant:
	_memo_lock.lock()
	var hit: bool = table.has(key)
	var v: Variant = table.get(key)
	_memo_lock.unlock()
	if hit:
		return v
	v = fn.call()
	_memo_lock.lock()
	table[key] = v
	_memo_lock.unlock()
	return v


static func _near_line(p: Vector2, lines: Array, r: float) -> bool:
	for line: PackedVector2Array in lines:
		for i in line.size() - 1:
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, line[i], line[i + 1])) < r:
				return true
	return false


## Dirt road between neighbouring villages a and b as a polyline (world x/z), gently curved; empty
## when either village is missing or the road would cross water or a steep slope. road(a, b) == road(b, a).
func road(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		var t := a
		a = b
		b = t
	return _memo(_roads, Vector4i(a.x, a.y, b.x, b.y), _road.bind(a, b))


## The (up to) ROAD_LINKS nearest villages within ROAD_MAX of village `g`'s square.
func _nearest_villages(g: Vector2i) -> Array:
	var c: Vector2 = village_site(g).centre
	var near := []
	for d in LINK_OFFSETS:
		var s := village_site(g + d)
		if not s.is_empty() and c.distance_to(s.centre) <= ROAD_MAX:
			near.append([c.distance_to(s.centre), g + d])
	near.sort()
	return near.slice(0, ROAD_LINKS).map(func(e): return e[1])


func _road(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	var va := village_site(a)
	var vb := village_site(b)
	if va.is_empty() or vb.is_empty() or not (b in _nearest_villages(a) or a in _nearest_villages(b)):
		return PackedVector2Array()
	var p0: Vector2 = va.centre
	var p2: Vector2 = vb.centre
	var bend := float(hash(Vector4i(noise.seed + 4, a.x, a.y, b.x * 7 + b.y)) & 0xFF) / 255.0 - 0.5
	var p1 := (p0 + p2) / 2.0 + (p2 - p0).orthogonal() * bend * 0.4
	var out := PackedVector2Array()
	for i in 17:
		var t := i / 16.0
		var p := p0.lerp(p1, t).lerp(p1.lerp(p2, t), t)  # quadratic Bézier
		if height(p.x, p.y) < WATER_LEVEL + 0.5 or _normal(p.x, p.y).y < 0.85:  # water or steep slope
			return PackedVector2Array()
		out.append(p)
	return out


## Everything man-made touching zone `cell`: the roads/houses mask (per terrain vertex: FREE, CLEAR,
## ROAD) and the zone's houses per kind (zone-local transforms). Thread-safe.
func layout(cell: Vector2i) -> Dictionary:
	var n := ZONE_SIZE + 1
	var half := ZONE_SIZE / 2.0
	var origin := Vector2(cell) * ZONE_SIZE
	var mask := PackedByteArray()
	mask.resize(n * n)
	var houses := []
	for k in HOUSE_KINDS:
		houses.append([] as Array[Transform3D])
	var reach := half + ROAD_MAX + VILLAGE_GRID  # a road touching this zone starts within this range
	var lo := Vector2i(((origin - Vector2.ONE * reach) / VILLAGE_GRID).floor())
	var hi := Vector2i(((origin + Vector2.ONE * reach) / VILLAGE_GRID).floor())
	var rect := Rect2(origin - Vector2.ONE * (half + ROAD_HALF + 3.0), Vector2.ONE * (ZONE_SIZE + 2 * (ROAD_HALF + 3.0)))
	for gx in range(lo.x, hi.x + 1):
		for gz in range(lo.y, hi.y + 1):
			var g := Vector2i(gx, gz)
			var sa := village_site(g)
			if sa.is_empty():
				continue
			for d in LINK_OFFSETS:
				if d.x < 0 or (d.x == 0 and d.y < 0):
					continue  # each pair once
				var sb := village_site(g + d)
				if sb.is_empty():
					continue
				var bb := Rect2(sa.centre, Vector2.ZERO).expand(sb.centre)
				if not bb.grow(sa.centre.distance_to(sb.centre) * 0.25).intersects(rect):
					continue  # can't reach this zone, skip before sampling the road
				var line := road(g, g + d)
				for i in line.size() - 1:
					_mark_segment(mask, line[i] - origin, line[i + 1] - origin, ROAD_HALF, ROAD_HALF + 3.0)
	for gx in range(lo.x, hi.x + 1):
		for gz in range(lo.y, hi.y + 1):
			var g := Vector2i(gx, gz)
			var v := village(g)
			if v.is_empty() or (v.centre - origin).abs().x > half + 40.0 or (v.centre - origin).abs().y > half + 40.0:
				continue
			_mark_segment(mask, v.centre - origin, v.centre - origin, 7.0, 9.0)  # the square
			for hs in v.houses:
				var lp := Vector2(hs[0].x, hs[0].z) - origin
				_mark_segment(mask, lp, lp, 0.0, 7.5)
				if absf(lp.x) < half and absf(lp.y) < half:
					houses[hs[2]].append(Transform3D(Basis(Vector3.UP, hs[1]), Vector3(lp.x, hs[0].y, lp.y)))
	return {"mask": mask, "houses": houses}


## Marks mask vertices within `road` of segment a-b (zone-local x/z) as ROAD, within `clear` as CLEAR.
func _mark_segment(mask: PackedByteArray, a: Vector2, b: Vector2, road_r: float, clear_r: float) -> void:
	var n := ZONE_SIZE + 1
	var half := ZONE_SIZE / 2
	var x0 := maxi(floori(minf(a.x, b.x) - clear_r) + half, 0)
	var x1 := mini(ceili(maxf(a.x, b.x) + clear_r) + half, n - 1)
	var z0 := maxi(floori(minf(a.y, b.y) - clear_r) + half, 0)
	var z1 := mini(ceili(maxf(a.y, b.y) + clear_r) + half, n - 1)
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x - half, z - half)
			var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))
			var i := z * n + x
			if d <= road_r:
				mask[i] = ROAD
			elif d <= clear_r and mask[i] == FREE:
				mask[i] = CLEAR


## True where the layout keeps the ground clear (zone-local x/z; empty mask = nothing blocked).
func _blocked(mask: PackedByteArray, lx: float, lz: float) -> bool:
	if mask.is_empty():
		return false
	var half := ZONE_SIZE / 2
	return mask[clampi(roundi(lz) + half, 0, ZONE_SIZE) * (ZONE_SIZE + 1) + clampi(roundi(lx) + half, 0, ZONE_SIZE)] != FREE


func rock_transforms(cell: Vector2i, mask := PackedByteArray()) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(noise.seed + 1, cell.x, cell.y))
	var half := ZONE_SIZE / 2.0
	var out := []
	for k in ROCK_KINDS:
		out.append([] as Array[Transform3D])
	for i in ROCK_ATTEMPTS:
		var lx := rng.randf_range(-half, half)
		var lz := rng.randf_range(-half, half)
		var keep := rng.randf()
		var kind := rng.randi() % ROCK_KINDS
		var s := rng.randf_range(0.6, 1.3)
		var rot := rng.randf() * TAU
		var wx := cell.x * ZONE_SIZE + lx
		var wz := cell.y * ZONE_SIZE + lz
		var h := height(wx, wz)
		if h < WATER_LEVEL + 0.3 or keep > 0.15 + 0.6 * hilliness(wx, wz) or _blocked(mask, lx, lz):
			continue
		var tilt := Basis(Quaternion(Vector3.UP, _normal(wx, wz)))
		out[kind].append(Transform3D((tilt * Basis(Vector3.UP, rot)).scaled(Vector3.ONE * s), Vector3(lx, h, lz)))
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
	var lay := layout(cell)
	var mask: PackedByteArray = lay.mask
	# Heights with a 1-vertex border, so normals reuse them instead of re-sampling the noise
	# (same formula as _normal, ~5x fewer noise calls).
	var g := n + 2
	var grid := PackedFloat32Array()
	grid.resize(g * g)
	for z in g:
		for x in g:
			grid[z * g + x] = height(origin.x + x - 1 - half, origin.y + z - 1 - half)
	for z in n:
		for x in n:
			var i := (z + 1) * g + x + 1
			var h := grid[i]
			var nrm := Vector3(grid[i - 1] - grid[i + 1], 2.0, grid[i - g] - grid[i + g]).normalized()
			verts.append(Vector3(x - half, h, z - half))
			normals.append(nrm)
			colors.append(ROAD_COLOR if mask[z * n + x] == ROAD else _ground_color(h, nrm.y))
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
	var trees := tree_transforms(cell, mask)
	var rocks := rock_transforms(cell, mask)
	return {"cell": cell, "arrays": arrays, "heights": heights, "min_h": min_h, "trees": trees,
		"rocks": rocks, "flowers": flower_transforms(cell, mask), "houses": lay.houses,
		"map": _map_tile(heights, colors, normals, trees, rocks, lay.houses, mask)}


## Top-down MAP_PX² image of a zone (1 px = 4 m): ground colours, hill shading, water, trees, rocks.
func _map_tile(heights: PackedFloat32Array, colors: PackedColorArray, normals: PackedVector3Array, trees: Array, rocks: Array, houses := [], mask := PackedByteArray()) -> Image:
	var n := ZONE_SIZE + 1
	var step := ZONE_SIZE / MAP_PX
	var light := Vector3(-1, 1.5, -1).normalized()  # from the north-west, like paper maps
	var tile := Image.create(MAP_PX, MAP_PX, false, Image.FORMAT_RGB8)
	for py in MAP_PX:
		for px in MAP_PX:
			var j := py * step * n + px * step
			var c := Color(0.2, 0.45, 0.7) if heights[j] < WATER_LEVEL else colors[j]
			tile.set_pixel(px, py, c * clampf(0.55 + 0.6 * normals[j].dot(light), 0.4, 1.2))
			if not mask.is_empty() and _block_has_road(mask, px * step, py * step, step):
				tile.set_pixel(px, py, Color(0.48, 0.35, 0.2))  # whole road, not just sampled vertices
	for group in [[trees, Color(0.08, 0.25, 0.1), 1], [rocks, Color(0.6, 0.6, 0.6), 1], [houses, Color(0.6, 0.18, 0.12), 2]]:
		for list in group[0]:
			for t: Transform3D in list:
				var p := Vector2i((Vector2(t.origin.x, t.origin.z) + Vector2.ONE * (ZONE_SIZE / 2.0)) / step)
				tile.fill_rect(Rect2i(p.clampi(0, MAP_PX - group[2]), Vector2i.ONE * group[2]), group[1])
	return tile


static func _block_has_road(mask: PackedByteArray, x0: int, z0: int, size: int) -> bool:
	var n := ZONE_SIZE + 1
	for z in range(z0, z0 + size):
		for x in range(x0, x0 + size):
			if mask[z * n + x] == ROAD:
				return true
	return false


## Light part, main thread: turn built data into nodes.
func _attach_zone(d: Dictionary) -> void:
	var cell: Vector2i = d.cell
	var n := ZONE_SIZE + 1
	var zone := Node3D.new()
	zone.name = "Zone_%d_%d" % [cell.x, cell.y]
	zone.position = Vector3(cell.x, 0, cell.y) * ZONE_SIZE
	map_tiles[cell] = d.map
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
	for model in all_trees.size():
		var trees: Array[Transform3D] = all_trees[model]
		if trees.is_empty():
			continue
		var tints := PackedColorArray()
		for t in trees:
			tints.append(seasons.leaf_color(model / TREE_VARIANTS, zone.position + t.origin))
		var mmi := _multimesh(species[model], trees, tints)
		mmi.set_meta("trees", trees)  # seasons.gd rebuilds the leaf colours from these
		zone.add_child(mmi)
		for t in trees:  # trunk collision only; crowns are above head height
			var tcs := CollisionShape3D.new()
			tcs.shape = trunk_shape
			tcs.position = t.origin + Vector3.UP
			body.add_child(tcs)

	var all_rocks: Array = d.rocks
	for kind in all_rocks.size():
		var rocks: Array[Transform3D] = all_rocks[kind]
		if rocks.is_empty():
			continue
		zone.add_child(_multimesh(rock_meshes[kind], rocks))
		if rock_shapes[kind]:
			for t in rocks:
				var rcs := CollisionShape3D.new()
				rcs.shape = rock_shapes[kind]
				rcs.transform = t  # uniform scale only, which Godot supports on shapes
				body.add_child(rcs)

	var all_houses: Array = d.houses
	for kind in all_houses.size():
		var list: Array[Transform3D] = all_houses[kind]
		if list.is_empty():
			continue
		zone.add_child(_multimesh(house_meshes[kind], list))
		for t in list:
			var hcs := CollisionShape3D.new()
			hcs.shape = house_shapes[kind]
			hcs.transform = t * Transform3D(Basis(), house_centres[kind])
			body.add_child(hcs)

	var all_flowers: Array = d.flowers
	for kind in all_flowers.size():
		var list: Array[Transform3D] = all_flowers[kind]
		if not list.is_empty():
			var mmi := _multimesh(flowers[kind].mesh, list)
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # hundreds of tiny plants
			zone.add_child(mmi)

	if d.min_h < WATER_LEVEL:
		var plane := PlaneMesh.new()
		plane.size = Vector2(ZONE_SIZE, ZONE_SIZE)
		plane.material = water_mat
		var water := MeshInstance3D.new()
		water.mesh = plane
		water.position.y = WATER_LEVEL
		zone.add_child(water)

	zone_trees[cell] = d.trees
	zones[cell] = zone
	add_child(zone)


## One draw call for every instance of `mesh` in a zone; `colors` (optional) tints each instance.
func _multimesh(mesh: Mesh, transforms: Array[Transform3D], colors := PackedColorArray()) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	return mmi


## Leaves (surface 1) multiply their colour by the MultiMesh instance colour; bark stays as is.
func _tintable_leaves(mesh: ArrayMesh) -> ArrayMesh:
	var mat := mesh.surface_get_material(1).duplicate() as StandardMaterial3D
	mat.vertex_color_use_as_albedo = true  # mesh has no vertex colours, so COLOR = instance colour
	mesh.surface_set_material(1, mat)
	return mesh


## Slight per-tree leaf colour shift: brightness ±15 %, yellower or bluer. Deterministic from position.
func leaf_tint(p: Vector3) -> Color:
	var h := hash(Vector2i(roundi(p.x * 10.0), roundi(p.z * 10.0)))
	var b := 0.85 + 0.3 * float(h & 0xFF) / 255.0
	var w := -0.08 + 0.18 * float((h >> 8) & 0xFF) / 255.0
	return Color(b * (1.0 + w), b, b * (1.0 - w))


func _ground_color(h: float, up: float) -> Color:
	if h < WATER_LEVEL + 1.5:
		return Color(0.76, 0.7, 0.5)  # sand / lakebed
	if up < 0.8:
		return Color(0.45, 0.42, 0.4)  # steep = rock
	if h > 22.0:
		return Color(0.92, 0.92, 0.95)  # peaks
	return Color(0.3, 0.55, 0.2)  # grass


func _update_hud() -> void:
	hud.text = "ZQSD/WASD bouger · Shift courir · Espace sauter/remonter · Souris regarder · V vue iso (molette zoom) · M carte · 1-4 saison · +/- heure · Échap souris\nZones : %d · Saison : %s · Heure : %s" % [zones.size(), seasons.NAMES[seasons.season], daynight.clock()]


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
