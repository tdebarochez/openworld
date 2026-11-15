extends Node3D
## Bounded open world made of square terrain zones.
## Heights come from one global noise field, so adjacent zones always join seamlessly.
## Press N to add a zone next to the one you stand in, in the direction you look.

const ZONE_SIZE := 128  # metres per side; 1 m grid so HeightMapShape3D needs no scaling
const WATER_LEVEL := 0.0
const AUTO_GEN_DIST := 50.0  # generate the neighbour zone when closer than this to an edge

var zones := {}  # Vector2i -> Node3D
var noise := FastNoiseLite.new()
var terrain_mat := StandardMaterial3D.new()
var water_mat := StandardMaterial3D.new()
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


func _ready() -> void:
	_setup_environment()
	add_zone(Vector2i.ZERO)
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


func cell_of(p: Vector3) -> Vector2i:
	return Vector2i(floori((p.x + ZONE_SIZE / 2.0) / ZONE_SIZE), floori((p.z + ZONE_SIZE / 2.0) / ZONE_SIZE))


## First free cell walking from `from` along `dir` — always touches an existing zone.
func next_free_cell(from: Vector2i, dir: Vector2i) -> Vector2i:
	var c := from + dir
	while zones.has(c):
		c += dir
	return c


## Neighbour cells to create for a player at `p`: one per near edge, plus the diagonal at a corner.
func cells_near_edges(p: Vector3) -> Array[Vector2i]:
	var cell := cell_of(p)
	var local := Vector2(p.x, p.z) - Vector2(cell) * ZONE_SIZE
	var limit := ZONE_SIZE / 2.0 - AUTO_GEN_DIST
	var dx := int(signf(local.x)) if absf(local.x) > limit else 0
	var dz := int(signf(local.y)) if absf(local.y) > limit else 0
	var out: Array[Vector2i] = []
	if dx:
		out.append(cell + Vector2i(dx, 0))
	if dz:
		out.append(cell + Vector2i(0, dz))
	if dx and dz:
		out.append(cell + Vector2i(dx, dz))
	return out


func _physics_process(_delta: float) -> void:
	var before := zones.size()
	for c in cells_near_edges(player.global_position):
		add_zone(c)
	if zones.size() != before:
		_update_hud()


func add_zone(cell: Vector2i) -> void:
	if zones.has(cell):
		return
	var zone := Node3D.new()
	zone.name = "Zone_%d_%d" % [cell.x, cell.y]
	zone.position = Vector3(cell.x, 0, cell.y) * ZONE_SIZE
	var n := ZONE_SIZE + 1
	var half := ZONE_SIZE / 2
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var heights := PackedFloat32Array()
	var min_h := INF
	for z in n:
		for x in n:
			var wx := zone.position.x + x - half
			var wz := zone.position.z + z - half
			var h := height(wx, wz)
			# Normal from the global field (not the mesh) so lighting matches across zone edges.
			var nrm := Vector3(height(wx - 1, wz) - height(wx + 1, wz), 2.0, height(wx, wz - 1) - height(wx, wz + 1)).normalized()
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, terrain_mat)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	zone.add_child(mi)

	var shape := HeightMapShape3D.new()
	shape.map_width = n
	shape.map_depth = n
	shape.map_data = heights
	var cs := CollisionShape3D.new()
	cs.shape = shape
	var body := StaticBody3D.new()
	body.add_child(cs)
	zone.add_child(body)

	if min_h < WATER_LEVEL:
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


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_N:
		var f: Vector3 = -player.camera.global_basis.z
		var dir := Vector2i(int(signf(f.x)), 0) if absf(f.x) > absf(f.z) else Vector2i(0, int(signf(f.z)))
		add_zone(next_free_cell(cell_of(player.global_position), dir))
		_update_hud()


func _update_hud() -> void:
	hud.text = "ZQSD/WASD bouger · Shift courir · Espace sauter · Souris regarder · N nouvelle zone · Échap souris\nZones : %d" % zones.size()


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
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
