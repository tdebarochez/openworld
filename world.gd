extends Node3D
## Open world made of square terrain zones, streamed in around the player (built on worker threads).
## Heights come from one global noise field, so adjacent zones always join seamlessly.

const ZONE_SIZE := 128  # metres per side; 1 m grid so HeightMapShape3D needs no scaling
const WATER_LEVEL := 0.0
const VIEW_DIST := 200.0  # default view distance: zones closer than this get generated; fog is fully opaque here
# P / O step the view distance and the density (multiplier of tree/rock/flower attempts) up,
# Shift+P / Shift+O down, wrapping around at both ends.
const VIEW_STEP := 100.0
const VIEW_MAX := 2000.0  # ~840 zones
const DENSITY_STEP := 0.5
const DENSITY_MAX := 10.0
const FOG_START := 0.3  # share of the view distance where the haze begins (full at the view distance)
# Light (colours: assets/palette.json): sun, sky fill (ambient energy; a flat colour in Compatibility),
# light soft sun shadows, AgX tonemapping and grade (saturation, then per-channel curves dark/mid/light).
const SUN_ENERGY := 1.05
const AMBIENT := 0.45
# Compatibility lights in sRGB: a little sun goes a long way, the flat ambient carries the shadows.
const COMPAT_SUN := 0.3
const COMPAT_AMBIENT := 0.75
const COMPAT_AGX_CONTRAST := 1.2
const SHADOW_OPACITY := 0.95
const SHADOW_BLUR := 1.5
const AGX_CONTRAST := 1.7
const GRADE_SATURATION := 1.4  # AgX desaturates bright colours: brought back after it
const GRADE := [Color(0.03, 0.05, 0.11), Color(0.53, 0.5, 0.46), Color(1.0, 0.97, 0.9)]  # bluish darks, warm lights
# Detail by distance. FULL: everything. LIGHT (beyond NEAR_DIST): terrain, trees, houses and water only —
# no rocks, flowers or collision (nothing out there can be touched). COARSE (beyond COARSE_DIST): LIGHT
# with a COARSE_RES m terrain grid (16x fewer triangles) and skirts hiding the cracks against finer
# neighbours. Zones are rebuilt as the player moves; a zone keeps its level half a zone past the
# threshold, so walking along it doesn't thrash.
enum Detail { FULL, LIGHT, COARSE }
const NEAR_DIST := 250.0
const COARSE_DIST := 1000.0
const COARSE_RES := 4  # m between coarse terrain vertices (= map pixel size)
const SKIRT := 4.0  # m the coarse zone's edges hang down
# Baked ground shading (_shading): soft painted depth without post-processing (the web has no SSAO).
const SHADE_STEP := COARSE_RES  # m between samples of the broad terms: the coarse grid itself
const HOLLOW_R := 8  # m: ground lower than the ring this far round is a hollow (or a slope's foot)
const HOLLOW_DARK := 0.22  # light lost 1.5 m or more below that ring
const CREST_LIGHT := 0.06  # light gained 1.5 m or more above it
const FOREST_DARK := 0.15  # light lost on the forest floor
const CONTACT := 0.3  # light lost at the foot of a tree, bush, rock or house wall
const HOUSE_SHADE := 3.0  # m the shade reaches out from a house
const SHADE_MIN := 0.62  # darkest the ground gets, however many shades overlap
const TREE_ATTEMPTS := 400  # random spots tried per zone; most are rejected (water, slope, clearing)
const TREE_VARIANTS := 3  # models per species (tools/make_trees.py)
const BUSH_CLUSTERS := 150  # bush groups tried per zone; only bushes on a forest edge are kept
const BUSH_VARIANTS := 3  # models per kind (tools/make_bushes.py)
const BUSH_EDGE := 0.15  # forest() band (~6 m) outside the edge (0) where bushes grow; half as wide under the trees
const ROCK_ATTEMPTS := 40  # ~6 rocks per zone on plains, ~30 in hills
const ROCK_KINDS := 5  # tools/make_rocks.py; rock_3 is a pebble (no collision)
const FLOWER_CLUSTERS := 40  # flower beds tried per zone; about half fit their species' habitat
const VILLAGE_GRID := 400.0  # one candidate village per 400 m square, kept only on flat plains
const HOUSE_KINDS := 6  # tools/make_houses.py: 0-2 medieval, 3-5 chalets
const HOUSE_VARIANTS := 3  # kinds per style
const LAMP_HEIGHT := 3.4  # m, bottom of the lantern
const LAMP_ARM := 0.55  # m from the pole to the lantern
const LAMP_LIGHT := Vector3(LAMP_ARM, LAMP_HEIGHT + 0.2, 0)  # lantern centre = light, in the lamp's frame
const LAMP_SHADOW_DIST := 35.0  # m from the camera within which a lamp casts shadows
const LAMP_ON_SUN := 0.05  # lamps light up once the sun is lower than this (dir.y, ~3° above the horizon)
enum Prop { BENCH, PLAIN_BENCH, PLANTER }  # village street furniture (_make_props); PLAIN = no backrest
const BENCH_RADIUS := 8.0  # m from the village centre: the edge of the dirt square, between the lamps
const PLANTER_TOP := 0.2  # m above the ground: the planter's soil, where its flowers stand
# Village cats (tools/make_cats.py): 0-3 per village, each on its own bench, coat = MultiMesh instance
# colour (palette "cats"). The model's origin goes on the seat's front edge (_make_props' seat box).
enum CatPose { SITTING, LYING }
const MAX_CATS := 3
const SEAT_TOP := 0.48  # m above the bench's foot
const SEAT_FRONT := 0.21  # m from the bench's centre line to the seat's front edge (+Z)
const CAT_SLIDE := 0.45  # m a cat sits at most from the middle of the bench, along it
# The tail swings around Z from its pivot (UV, model space), as much as COLOR.a says (0 on the body,
# 1 at the tip); the phase comes from the cat's position, so a zone's cats are one MultiMesh and no
# script runs per frame. COLOR.rgb = baked shading × coat, sRGB like StandardMaterial3D's.
const CAT_SHADER := """
shader_type spatial;
uniform float sway = 0.35;  // rad at the tip
void vertex() {
	float t = TIME * 1.4 + dot(MODEL_MATRIX[3].xz, vec2(1.3, 2.1));
	float a = COLOR.a * sway * (sin(t) + 0.3 * sin(t * 2.7 + 1.0));
	mat2 r = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
	VERTEX.xy = UV + r * (VERTEX.xy - UV);
	NORMAL.xy = r * NORMAL.xy;
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 0.9;
}
"""
# Village flowers: tulips (spring) in front of one of the summer bloomers, picked per planter or clump.
const VILLAGE_FLOWERS := ["tulip", "poppy", "sunflower", "heather"]
const ROAD_HALF := 2.0  # road half-width, metres
const ROAD_LINKS := 2  # each village gets a road to its nearest villages…
const ROAD_MAX := 900.0  # …within this distance
const LINK_OFFSETS: Array[Vector2i] = [  # squares searched for neighbours (5x5 minus the centre)
	Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2), Vector2i(1, -2), Vector2i(2, -2),
	Vector2i(-2, -1), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(2, -1),
	Vector2i(-2, 0), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(2, 0),
	Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
	Vector2i(-2, 2), Vector2i(-1, 2), Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2)]
enum { FREE, CLEAR, ROAD }  # layout mask: CLEAR = no trees/rocks/flowers, ROAD = dirt surface too
const MAX_JOBS := 4  # zones built in parallel on worker threads
const MAP_PX := 32  # map pixels per zone side (4 m per pixel)
enum TreeKind { CONIFER, OAK, BIRCH }
enum BushKind { HAZEL, HOLLY, BRAMBLE }
# Seasons treat each BushKind like this TreeKind: hazel bare in winter, holly evergreen with snow,
# bramble keeping the odd dead leaf.
const BUSH_LEAVES := [TreeKind.BIRCH, TreeKind.CONIFER, TreeKind.OAK]

var view_dist := VIEW_DIST
# Placement attempts are drawn in a fixed order, so a higher density keeps every existing object and adds more.
var density := 1.0
var built := {}  # Vector2i -> [density, Detail] the loaded zone was built with; outdated ones are rebuilt nearest first
var zones := {}  # Vector2i -> Node3D
var zone_trees := {}  # Vector2i -> the zone's `trees` data (zone-local, per model); birds.gd perches on them
var map_tiles := {}  # Vector2i -> Image, top-down view of each generated zone
var jobs := {}  # Vector2i -> {task: int, data: Dictionary} for zones being built on a worker thread
var threaded := OS.has_feature("threads")  # false in the web export (no-threads build)
var noise := FastNoiseLite.new()
var seasons := preload("res://seasons.gd").new()
var terrain_mat: ShaderMaterial = seasons.terrain_mat  # recolours the vertex colours per season
var ground: Array = seasons.GROUND[seasons.Season.SUMMER]  # sand, rock, peak, grass, road: baked into the terrain
var road_color: Color = ground[4]  # dirt; seasons.gd recolours it (5th ground key)
var lamp_color := seasons.colour("lamp")
var daynight  # daynight.gd, made in _ready
var weather  # weather.gd, same
var water_mat := StandardMaterial3D.new()
var species: Array[Mesh] = []  # indexed by kind * TREE_VARIANTS + variant
var bush_meshes: Array[Mesh] = []  # indexed by kind * BUSH_VARIANTS + variant
var trunk_shape := CylinderShape3D.new()
var rock_meshes: Array[Mesh] = []
var rock_shapes: Array[Shape3D] = []  # convex hull per rock kind, null for the pebble
# From assets/flowers/flowers.json (tools/make_flowers.py): name, bloom (season names), habitat, …
# plus "mesh". Surface 0 = foliage, surfaces ≥ 1 = blossom (seasons.gd hides them out of season).
var flowers: Array = []
var house_meshes: Array[Mesh] = []
var house_shapes: Array[BoxShape3D] = []  # per kind, the walls' box (eaves and balconies excluded)
var house_centres: Array[Vector3] = []  # per kind, centre of that box in the house's frame
var house_low: Array[Rect2] = []  # per kind, x/z extent of all lower than a lantern (balconies, porch, low eaves)
var house_radius: Array[float] = []  # per kind, from the origin to the farthest roof corner (x/z)
# Village street lamps: dark pole + lantern (lit at night), a shadow-casting OmniLight each in full zones.
var lamp_meshes: Array[ArrayMesh] = []
var lamp_glass := StandardMaterial3D.new()
var lamp_shape := CylinderShape3D.new()
var lamps_on := false
var lamp_fade := true  # off in the iso view, whose camera is 100 m away (every lamp would fade out)
var prop_meshes: Array[ArrayMesh] = []  # per Prop
var prop_shapes: Array[BoxShape3D] = []  # per Prop, the mesh's box
var prop_centres: Array[Vector3] = []
var cat_meshes: Array[ArrayMesh] = []  # per CatPose; surface 0 = coat (cat_mat), 1 = eyes, 2 = nose
var cat_mat := ShaderMaterial.new()
var cat_coats: Array = seasons.colours(seasons.palette.cats)
# Memoised village sites / villages / roads (pure functions of the seed), shared by worker threads.
var _sites := {}
var _villages := {}
var _roads := {}
var _memo_lock := Mutex.new()
var player: CharacterBody3D
var hud := Label.new()
var fps := Label.new()  # bottom right: frames per second (engine's 1 s average) and visible polygons


func _init() -> void:
	noise.seed = 1337
	noise.frequency = 0.004
	noise.fractal_octaves = 5
	seasons.world = self
	add_child(seasons)
	water_mat.albedo_color = Color(seasons.colour("water"), 0.75)
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water_mat.roughness = 0.05
	# Models from tools/make_trees.py and tools/make_rocks.py (Blender), base at origin.
	for file in ["conifer", "oak", "birch"]:  # TreeKind order
		for v in TREE_VARIANTS:
			species.append(_tintable_leaves(_load_mesh("res://assets/trees/%s_%d.glb" % [file, v])))
	for file in ["hazel", "holly", "bramble"]:  # BushKind order
		for v in BUSH_VARIANTS:
			bush_meshes.append(_tintable_leaves(_load_mesh("res://assets/bushes/%s_%d.glb" % [file, v])))
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
		# Collision box from the plinth top and the foot of the walls (wall and stone surfaces 0.25-1.2 m
		# up, so the eaves, jetties and balconies don't widen it), from the ground to the roof top.
		var box := AABB()
		var low := Rect2()
		for s in m.get_surface_count():
			for v: Vector3 in m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				if v.y < LAMP_HEIGHT + 0.8:
					low = low.expand(Vector2(v.x, v.z))
				if (s == 0 or s == 4) and v.y > 0.25 and v.y < 1.2:
					box = box.expand(v)
		box.end.y = m.get_aabb().end.y
		var shape := BoxShape3D.new()
		shape.size = box.size
		house_shapes.append(shape)
		house_centres.append(box.get_center())
		house_low.append(low)
		var full := m.get_aabb()
		house_radius.append(Vector2(maxf(-full.position.x, full.end.x), maxf(-full.position.z, full.end.z)).length())
	_make_lamp()
	_make_props()
	cat_mat.shader = Shader.new()
	cat_mat.shader.code = CAT_SHADER
	for pose in ["sitting", "lying"]:  # CatPose order
		var m := _load_mesh("res://assets/cats/cat_%s.glb" % pose)
		m.surface_set_material(0, cat_mat)
		for s in [1, 2]:  # eyes and nose keep their colour on any coat (COLOR carries the instance's)
			(m.surface_get_material(s) as StandardMaterial3D).vertex_color_use_as_albedo = false
		cat_meshes.append(m)
	trunk_shape.radius = 0.3
	trunk_shape.height = 2.0


## Models carry their baked shading (tools/make_trees.py bake_shade) as sRGB vertex colours, which
## multiply every material's colour (and a tree's instance colour on its leaves).
func _load_mesh(path: String) -> ArrayMesh:
	var scene: Node = load(path).instantiate()
	var mesh := (scene.find_children("", "MeshInstance3D")[0] as MeshInstance3D).mesh as ArrayMesh
	scene.free()
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s) as StandardMaterial3D
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
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
	weather = preload("res://weather.gd").new()
	weather.world = self
	add_child(weather)
	add_child(preload("res://birds.gd").new())  # finds the world as its parent
	add_child(preload("res://clouds.gd").new())  # same
	var layer := CanvasLayer.new()
	var map := preload("res://map.gd").new()
	map.world = self
	layer.add_child(map)
	hud.position = Vector2(12, 12)
	layer.add_child(hud)
	fps.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	fps.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	fps.grow_vertical = Control.GROW_DIRECTION_BEGIN
	fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	layer.add_child(fps)
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
	for i in roundi(TREE_ATTEMPTS * density):
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
		if forest(wx, wz) < 0.0:  # forests vs clearings
			continue
		# Species in groves: conifers up high, oak/birch patches below.
		var v := noise.get_noise_2d(wx * 2.0 - 7000.0, wz * 2.0)
		var kind := TreeKind.CONIFER if h > 14.0 or v < -0.1 else (TreeKind.OAK if v < 0.1 else TreeKind.BIRCH)
		# Variant from position, not the RNG, so adding variants never moved existing trees.
		var variant := hash(Vector3i(roundi(wx * 10.0), roundi(wz * 10.0), 7)) % TREE_VARIANTS
		out[kind * TREE_VARIANTS + variant].append(Transform3D(Basis(Vector3.UP, rot).scaled(Vector3.ONE * s), Vector3(lx, h, lz)))
	return out


## Forest field: trees grow where it is ≥ 0, clearings below; forest edges are where it crosses 0.
func forest(x: float, z: float) -> float:
	return noise.get_noise_2d(x * 4.0 + 5000.0, z * 4.0)


## Bush placements per model (zone-local), in groups of one kind along forest edges: a band of
## forest() on both sides of 0, densest right at the edge and half as wide under the outer trees.
## Deterministic per seed + cell.
func bush_transforms(cell: Vector2i, mask := PackedByteArray()) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(noise.seed + 5, cell.x, cell.y))
	var half := ZONE_SIZE / 2.0
	var out := []
	for k in BushKind.size() * BUSH_VARIANTS:
		out.append([] as Array[Transform3D])
	for c in roundi(BUSH_CLUSTERS * density):
		var cx := rng.randf_range(-half, half)
		var cz := rng.randf_range(-half, half)
		var kind := rng.randi() % BushKind.size()
		var spots := []  # all drawn before any rejection, so the RNG sequence stays fixed
		for i in rng.randi_range(2, 6):
			spots.append([rng.randfn(0.0, 3.0), rng.randfn(0.0, 3.0), rng.randf(), rng.randf_range(0.8, 1.25), rng.randf() * TAU])
		for sp in spots:
			var lx := clampf(cx + sp[0], -half, half - 0.01)
			var lz := clampf(cz + sp[1], -half, half - 0.01)
			var wx := cell.x * ZONE_SIZE + lx
			var wz := cell.y * ZONE_SIZE + lz
			var e := forest(wx, wz)
			if sp[2] >= 1.0 - absf(e) / (BUSH_EDGE if e < 0.0 else BUSH_EDGE * 0.5):  # 1 at the edge → 0 at the band's end
				continue
			var h := height(wx, wz)
			if h < WATER_LEVEL + 1.0 or h > 20.0 or _normal(wx, wz).y < 0.85 or _blocked(mask, lx, lz):
				continue
			var variant := hash(Vector3i(roundi(wx * 10.0), roundi(wz * 10.0), 8)) % BUSH_VARIANTS
			out[kind * BUSH_VARIANTS + variant].append(Transform3D(Basis(Vector3.UP, sp[4]).scaled(Vector3.ONE * sp[3]), Vector3(lx, h, lz)))
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
	for c in roundi(FLOWER_CLUSTERS * density):
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
	# One style per village, chalets likelier on less flat sites, and the odd house of the other style.
	var chalets := rng.randf() < 0.4 + 3.0 * hilliness(c.x, c.y)
	var count := rng.randi_range(4, 9)
	for i in count:
		var a := TAU * i / count + rng.randf_range(-0.25, 0.25)
		var kind := (int(chalets) ^ int(rng.randf() < 0.12)) * HOUSE_VARIANTS + rng.randi() % HOUSE_VARIANTS
		var rad := house_radius[kind]
		var r := rng.randf_range(9.0, 17.0) + rad  # roof clear of the square and its lamps
		var p := c + Vector2(cos(a), sin(a)) * r
		var ph := height(p.x, p.y)
		if ph < WATER_LEVEL + 1.0 or _normal(p.x, p.y).y < 0.9 or _near_line(p, roads, rad + ROAD_HALF) \
				or houses.any(func(o): return Vector2(o[0].x, o[0].z).distance_to(p) < rad + house_radius[o[2]]):
			continue
		var to_square := c - p
		houses.append([Vector3(p.x, ph - 0.1, p.y), atan2(to_square.x, to_square.y), kind])
	# Street lamps: five round the square (inside its clearing) and one beside each front door, in
	# front of the balcony or porch; none on a road or in a house.
	var spots: Array[Vector2] = []
	for i in 5:
		spots.append(c + Vector2.from_angle(TAU * i / 5.0 + 0.3) * 8.3)
	for hs in houses:
		var front: Vector3 = Basis(Vector3.UP, hs[1]) * Vector3(2.4, 0, house_low[hs[2]].end.y + 0.8)  # doors face +Z
		spots.append(Vector2(hs[0].x + front.x, hs[0].z + front.z))
	var lamps := []  # [world position on the ground, yaw]: the arm (+X) reaches towards the square
	for p in spots:
		if not _near_line(p, roads, ROAD_HALF + 1.0) and height(p.x, p.y) > WATER_LEVEL + 0.5 and not in_house(p, houses):
			var to_square := c - p
			lamps.append([Vector3(p.x, height(p.x, p.y), p.y), atan2(-to_square.y, to_square.x)])
	# Benches between the square's lamps, facing its centre, each with a flower clump behind; a planter
	# against each house's front wall at both corners (doors sit nearer the middle). Nothing on a road,
	# in a house or against a lamp. Every value is drawn even for rejected spots.
	var props := []  # [world position on the ground, yaw, Prop]: benches face +Z, planters run along X
	var plants := []  # [world position, yaw, flower kind, scale]
	var fk: Array = VILLAGE_FLOWERS.map(func(n): return flowers.find_custom(func(f): return f.name == n))
	for i in 5:
		var a := TAU * (i + 0.5) / 5.0 + 0.3
		var kind := rng.randi() % 2  # BENCH or PLAIN_BENCH
		var p := c + Vector2.from_angle(a) * BENCH_RADIUS
		if not _near_line(p, roads, ROAD_HALF + 1.0) and not in_house(p, houses, 1.0) and _far_from(p, lamps + props, 1.5):
			props.append([Vector3(p.x, height(p.x, p.y), p.y), atan2(c.x - p.x, c.y - p.y), kind])
		var pair := [fk[0], fk[rng.randi_range(1, fk.size() - 1)]]
		for j in 7:  # a ring of six round a seventh
			var q := c + Vector2.from_angle(a) * (BENCH_RADIUS + 1.8)
			q += Vector2.ZERO if j == 6 else Vector2.from_angle(TAU * j / 6.0) * rng.randf_range(0.35, 0.45)
			var yaw := rng.randf() * TAU
			var s := rng.randf_range(0.8, 1.15)
			if not _near_line(q, roads, ROAD_HALF + 0.5) and not in_house(q, houses, 0.2) and _far_from(q, lamps + props, 1.0):
				plants.append([Vector3(q.x, height(q.x, q.y), q.y), yaw, pair[j % 2], s])
	for hs in houses:
		var pair := [fk[rng.randi_range(1, fk.size() - 1)], fk[0]]  # back row, front row (tulips)
		var size: Vector3 = house_shapes[hs[2]].size
		var hc: Vector3 = house_centres[hs[2]]
		var rot := Basis(Vector3.UP, hs[1])
		for side in [1, -1]:
			# Planter centre at a front corner, just clear of the walls and of anything low out front
			# (house_low: balcony posts, porch, gallery).
			var lp := Vector3(hc.x + side * (size.x / 2.0 - 0.8), 0, house_low[hs[2]].end.y + 0.45)
			var w: Vector3 = hs[0] + rot * lp
			var p := Vector2(w.x, w.z)
			var top := height(p.x, p.y) + PLANTER_TOP
			var bed := []
			for j in 8:  # two rows of four
				var l: Vector3 = hs[0] + rot * (lp + Vector3((j % 4 - 1.5) * 0.3 + rng.randfn(0, 0.03), 0, (j / 4 - 0.5) * 0.28))
				bed.append([Vector3(l.x, top, l.z), rng.randf() * TAU, pair[j / 4], rng.randf_range(0.8, 1.15)])
			if not _near_line(p, roads, ROAD_HALF + 1.0) and _far_from(p, lamps + props, 1.0) \
					and bed.all(func(b): return not in_house(Vector2(b[0].x, b[0].z), houses, 0.1)):
				props.append([Vector3(p.x, top - PLANTER_TOP, p.y), hs[1], Prop.PLANTER])
				plants.append_array(bed)
	# Cats from their own dice, so changes above never move them: each on a different bench.
	var cat_rng := RandomNumberGenerator.new()
	cat_rng.seed = hash(site.seed + 6)
	var free_benches := props.filter(func(o): return o[2] != Prop.PLANTER)
	var cats := []  # [bench position, bench yaw, CatPose, coat (cat_coats index), m along the seat]
	for i in mini(cat_rng.randi_range(0, MAX_CATS), free_benches.size()):
		var b: Array = free_benches.pop_at(cat_rng.randi() % free_benches.size())
		cats.append([b[0], b[1], cat_rng.randi() % CatPose.size(), cat_rng.randi() % cat_coats.size(),
			cat_rng.randf_range(-CAT_SLIDE, CAT_SLIDE)])
	return {"centre": c, "houses": houses, "lamps": lamps, "props": props, "flowers": plants, "cats": cats}


## True if `p` (world x/z) is at least `r` from every [world position, …] of `things`.
static func _far_from(p: Vector2, things: Array, r: float) -> bool:
	return things.all(func(o): return Vector2(o[0].x, o[0].z).distance_to(p) >= r)


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


## True when world x/z point `p` is within `margin` of one of `houses` ([position, yaw, kind]) or of
## anything of it lower than a lantern (house_low: balconies, porch, low eaves).
func in_house(p: Vector2, houses: Array, margin := 0.5) -> bool:
	for hs in houses:
		var l: Vector3 = Basis(Vector3.UP, -hs[1]) * Vector3(p.x - hs[0].x, 0, p.y - hs[0].z)
		if house_low[hs[2]].grow(margin).has_point(Vector2(l.x, l.z)):
			return true
	return false


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
## ROAD), the zone's houses per kind (zone-local transforms) and the houses near it. Thread-safe.
func layout(cell: Vector2i) -> Dictionary:
	var n := ZONE_SIZE + 1
	var half := ZONE_SIZE / 2.0
	var origin := Vector2(cell) * ZONE_SIZE
	var mask := PackedByteArray()
	mask.resize(n * n)
	var houses := []
	for k in HOUSE_KINDS:
		houses.append([] as Array[Transform3D])
	var lamps: Array[Transform3D] = []
	var props := []  # per Prop
	for k in Prop.size():
		props.append([] as Array[Transform3D])
	var plants := []  # per flower kind
	for k in flowers.size():
		plants.append([] as Array[Transform3D])
	var cats := []  # per CatPose: [transforms, coat colours]
	for k in CatPose.size():
		cats.append([[] as Array[Transform3D], []])
	var near := []  # every house of the villages around, even across the edge: [world position, yaw, kind]
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
			near.append_array(v.houses)
			for hs in v.houses:
				var lp := Vector2(hs[0].x, hs[0].z) - origin
				_mark_segment(mask, lp, lp, 0.0, house_radius[hs[2]] + 1.0)
				if absf(lp.x) < half and absf(lp.y) < half:
					houses[hs[2]].append(Transform3D(Basis(Vector3.UP, hs[1]), Vector3(lp.x, hs[0].y, lp.y)))
			for lamp in v.lamps:
				var ll: Vector3 = lamp[0] - Vector3(origin.x, 0, origin.y)
				if absf(ll.x) < half and absf(ll.z) < half:
					lamps.append(Transform3D(Basis(Vector3.UP, lamp[1]), ll))
			for pr in v.props:
				var pl: Vector3 = pr[0] - Vector3(origin.x, 0, origin.y)
				if absf(pl.x) < half and absf(pl.z) < half:
					props[pr[2]].append(Transform3D(Basis(Vector3.UP, pr[1]), pl))
			for f in v.flowers:  # own data, so the CLEAR mask doesn't drop them
				var fl: Vector3 = f[0] - Vector3(origin.x, 0, origin.y)
				if absf(fl.x) < half and absf(fl.z) < half:
					plants[f[2]].append(Transform3D(Basis(Vector3.UP, f[1]).scaled(Vector3.ONE * f[3]), fl))
			for cat in v.cats:  # in the zone of its bench
				var bl: Vector3 = cat[0] - Vector3(origin.x, 0, origin.y)
				if absf(bl.x) < half and absf(bl.z) < half:
					var rot := Basis(Vector3.UP, cat[1])
					cats[cat[2]][0].append(Transform3D(rot, bl + rot * Vector3(cat[4], SEAT_TOP, SEAT_FRONT)))
					cats[cat[2]][1].append(cat_coats[cat[3]])
	return {"mask": mask, "houses": houses, "lamps": lamps, "props": props, "flowers": plants, "cats": cats, "near_houses": near}


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
	for i in roundi(ROCK_ATTEMPTS * density):
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


## The Detail the zone at `cell` should have, seen from `p` (with half a zone of hysteresis).
func wants_detail(p: Vector3, cell: Vector2i) -> Detail:
	var d := dist_to_cell(p, cell)
	var was: int = built[cell][1] if built.has(cell) else -1
	var pad := ZONE_SIZE * 0.5
	if d <= NEAR_DIST + (pad if was == Detail.FULL else 0.0):
		return Detail.FULL
	if d > COARSE_DIST - (pad if was == Detail.COARSE else 0.0):
		return Detail.COARSE
	return Detail.LIGHT


## The player can only walk on fully built zones (the others have no collision).
func is_solid(cell: Vector2i) -> bool:
	return built.has(cell) and built[cell][1] == Detail.FULL


func _outdated(p: Vector3, cell: Vector2i) -> bool:
	return not built.has(cell) or built[cell] != [density, wants_detail(p, cell)]


## Cells within view_dist of `p` that are not generated yet or need a rebuild (density or detail), nearest first.
func missing_cells_near(p: Vector3) -> Array[Vector2i]:
	var c := cell_of(p)
	var r := ceili(view_dist / ZONE_SIZE) + 1
	var out: Array[Vector2i] = []
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var cell := c + Vector2i(dx, dz)
			if not jobs.has(cell) and dist_to_cell(p, cell) <= view_dist and _outdated(p, cell):
				out.append(cell)
	out.sort_custom(func(a, b): return dist_to_cell(p, a) < dist_to_cell(p, b))
	return out


## Street lamp model: lamp_meshes[0] = pole and cap (dark metal), [1] = lantern (`lamp_glass`).
func _make_lamp() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = seasons.colour("ink")
	metal.roughness = 0.6
	lamp_glass.albedo_color = seasons.colour("cream")
	lamp_glass.emission_enabled = true
	lamp_glass.emission = lamp_color
	lamp_glass.emission_energy_multiplier = 0.0  # set_lamps() turns it up at night
	# Bracket lamp: the lantern hangs from an arm, so the pole isn't under its own light (right below
	# the light, even a thin pole top throws a metre-wide disc of shadow on the ground).
	var pole := CylinderMesh.new()
	pole.top_radius = 0.05
	pole.bottom_radius = 0.08
	pole.height = LAMP_HEIGHT + 0.6
	pole.radial_segments = 6
	pole.rings = 1
	var arm := BoxMesh.new()
	arm.size = Vector3(LAMP_ARM + 0.1, 0.06, 0.06)
	var cap := CylinderMesh.new()
	cap.top_radius = 0.03
	cap.bottom_radius = 0.25
	cap.height = 0.2
	cap.radial_segments = 6
	cap.rings = 1
	var glass := BoxMesh.new()
	glass.size = Vector3(0.3, 0.4, 0.3)
	var top := LAMP_HEIGHT + 0.57
	# Two meshes: the post casts shadows, the lantern can't (its own light sits inside it).
	for part in [[[pole, Vector3(0, (LAMP_HEIGHT + 0.6) / 2.0, 0)], [arm, Vector3(LAMP_ARM / 2.0, top, 0)],
			[cap, Vector3(LAMP_ARM, LAMP_HEIGHT + 0.5, 0)]], [[glass, LAMP_LIGHT]]]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for piece in part:
			st.append_from(piece[0], 0, Transform3D(Basis(), piece[1]))
		lamp_meshes.append(st.commit())
	lamp_meshes[0].surface_set_material(0, metal)
	lamp_meshes[1].surface_set_material(0, lamp_glass)
	lamp_shape.radius = 0.1
	lamp_shape.height = LAMP_HEIGHT + 0.6


## Village props (per Prop), base on the ground: benches (seat facing +Z, wooden boards on stone legs),
## with or without a two-board backrest, and a stone planter filled with soil up to PLANTER_TOP.
## Stone parts are sunk 0.1-0.15 m for uneven ground.
func _make_props() -> void:
	var mats := []
	for c in ["bark", "stone", "ink"]:  # wood, stone, soil
		var m := StandardMaterial3D.new()
		m.albedo_color = seasons.colour(c)
		m.roughness = 0.9
		mats.append(m)
	# [size, centre] of each box, metres
	var seat := [[Vector3(1.6, 0.06, 0.42), Vector3(0, 0.45, 0)]]
	var back := [[Vector3(1.6, 0.12, 0.03), Vector3(0, 0.66, -0.2)], [Vector3(1.6, 0.12, 0.03), Vector3(0, 0.84, -0.2)],
		[Vector3(0.06, 0.48, 0.05), Vector3(-0.6, 0.66, -0.24)], [Vector3(0.06, 0.48, 0.05), Vector3(0.6, 0.66, -0.24)]]
	var legs := [[Vector3(0.14, 0.57, 0.5), Vector3(-0.6, 0.135, -0.04)], [Vector3(0.14, 0.57, 0.5), Vector3(0.6, 0.135, -0.04)]]
	var planter := [[Vector3(1.3, PLANTER_TOP + 0.1, 0.6), Vector3(0, (PLANTER_TOP - 0.1) / 2.0, 0)]]
	var soil := [[Vector3(1.16, 0.02, 0.46), Vector3(0, PLANTER_TOP, 0)]]
	for parts in [[[seat + back, mats[0]], [legs, mats[1]]], [[seat, mats[0]], [legs, mats[1]]],  # Prop order
			[[planter, mats[1]], [soil, mats[2]]]]:
		var mesh: ArrayMesh = null
		for part in parts:
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			for b in part[0]:
				var box := BoxMesh.new()
				box.size = b[0]
				st.append_from(box, 0, Transform3D(Basis(), b[1]))
			st.set_material(part[1])
			mesh = st.commit(mesh)
		prop_meshes.append(mesh)
		var shape := BoxShape3D.new()
		shape.size = mesh.get_aabb().size
		prop_shapes.append(shape)
		prop_centres.append(mesh.get_aabb().get_center())


## Lanterns glow and their lights shine from dusk to dawn.
func set_lamps(on: bool) -> void:
	lamps_on = on
	lamp_glass.emission_energy_multiplier = 3.0 if on else 0.0
	for light in get_tree().get_nodes_in_group("lamp_light"):
		light.visible = on


func set_lamp_fade(on: bool) -> void:
	lamp_fade = on
	for light in get_tree().get_nodes_in_group("lamp_light"):
		light.distance_fade_enabled = on


func _process(_delta: float) -> void:
	var night: bool = daynight.sun_dir(daynight.time, daynight.DECLINATION[seasons.season]).y < LAMP_ON_SUN
	if night != lamps_on:
		set_lamps(night)
	var f := Engine.get_frames_per_second()
	# Triangles drawn by the camera pass (shadow passes excluded).
	var tris := get_viewport().get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	fps.text = "%d FPS · %.1f ms · %.2f M polygones" % [f, 1000.0 / maxf(f, 1.0), tris / 1e6]


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
	var p := player.global_position
	for cell in missing_cells_near(p):
		var detail := wants_detail(p, cell)
		if not threaded:  # no threads (web): one synchronous zone per frame
			add_zone(cell, detail)
			_update_hud()
			break
		if jobs.size() >= MAX_JOBS:
			break
		var job := {"task": -1, "data": {}}
		job.task = WorkerThreadPool.add_task(func(): job.data = _build_zone(cell, detail))
		jobs[cell] = job


func _exit_tree() -> void:
	for job in jobs.values():
		WorkerThreadPool.wait_for_task_completion(job.task)


## Synchronous build + attach (startup, web and tests); skipped if already built that way.
func add_zone(cell: Vector2i, detail := Detail.FULL) -> void:
	if built.get(cell) != [density, detail]:
		_attach_zone(_build_zone(cell, detail))


## Heavy part, thread-safe: only reads the noise and returns plain data. See Detail for the levels.
func _build_zone(cell: Vector2i, detail := Detail.FULL) -> Dictionary:
	var dens := density  # read first: if it changes mid-build, the zone is tagged old and rebuilt
	var full := detail == Detail.FULL
	var res := COARSE_RES if detail == Detail.COARSE else 1  # metres between terrain vertices
	var origin := Vector2(cell) * ZONE_SIZE
	var cells := ZONE_SIZE / res
	var n := cells + 1
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
			grid[z * g + x] = height(origin.x + (x - 1) * res - half, origin.y + (z - 1) * res - half)
	var mn := ZONE_SIZE + 1  # the layout mask is always 1 m
	for z in n:
		for x in n:
			var i := (z + 1) * g + x + 1
			var h := grid[i]
			var nrm := Vector3(grid[i - 1] - grid[i + 1], 2.0 * res, grid[i - g] - grid[i + g]).normalized()
			verts.append(Vector3(x * res - half, h, z * res - half))
			normals.append(nrm)
			colors.append(road_color if mask[z * res * mn + x * res] == ROAD else _ground_color(h, nrm.y))
			heights.append(h)
			min_h = minf(min_h, h)
	var trees := tree_transforms(cell, mask)
	var rocks := rock_transforms(cell, mask) if full else []
	var bushes := bush_transforms(cell, mask) if full else []
	var uvs := _shading(cell, res, mask, [[trees, 2.8], [bushes, 1.4], [rocks, 1.3]], lay.near_houses)

	var idx := PackedInt32Array()
	for z in cells:
		for x in cells:
			var i := z * n + x
			idx.append_array([i, i + 1, i + n, i + 1, i + n + 1, i + n])
	if detail == Detail.COARSE:
		# Skirts: each edge repeated SKIRT m lower and joined to it, so the 4 m edge never shows a gap
		# against a finer neighbour's 1 m edge (the terrain material is double-sided).
		for edge in [range(0, n), range(n * (n - 1), n * n), range(0, n * n, n), range(n - 1, n * n, n)]:
			var base := verts.size()
			for i: int in edge:
				verts.append(verts[i] - Vector3(0, SKIRT, 0))
				normals.append(normals[i])
				colors.append(colors[i])
				uvs.append(uvs[i])
			for k in n - 1:
				idx.append_array([edge[k], edge[k + 1], base + k, edge[k + 1], base + k + 1, base + k])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var flw := flower_transforms(cell, mask) if full else []
	for k in flw.size():
		flw[k].append_array(lay.flowers[k])  # village beds share the wild flowers' MultiMesh
	return {"cell": cell, "density": dens, "detail": detail, "arrays": arrays, "heights": heights, "min_h": min_h, "trees": trees,
		"rocks": rocks, "flowers": flw, "houses": lay.houses,
		"bushes": bushes,
		"lamps": lay.lamps if full else ([] as Array[Transform3D]), "props": lay.props if full else [],
		"cats": lay.cats if full else [],
		"map": _map_tile(heights, colors, normals, trees, rocks, lay.houses, mask, res)}


## Top-down MAP_PX² image of a zone (1 px = 4 m): ground colours, hill shading, water, trees, rocks.
## `res`: metres between the given terrain samples (1, or COARSE_RES); `mask` is always 1 m.
func _map_tile(heights: PackedFloat32Array, colors: PackedColorArray, normals: PackedVector3Array, trees: Array, rocks: Array, houses := [], mask := PackedByteArray(), res := 1) -> Image:
	var n := ZONE_SIZE / res + 1
	var step := ZONE_SIZE / MAP_PX
	var light := Vector3(-1, 1.5, -1).normalized()  # from the north-west, like paper maps
	var tile := Image.create(MAP_PX, MAP_PX, false, Image.FORMAT_RGB8)
	for py in MAP_PX:
		for px in MAP_PX:
			var j := (py * n + px) * step / res
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

	var body: StaticBody3D = null  # light and coarse (far) zones have no collision at all
	if d.detail == Detail.FULL:
		var shape := HeightMapShape3D.new()
		shape.map_width = n
		shape.map_depth = n
		shape.map_data = d.heights
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body = StaticBody3D.new()
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
		for t in trees if body else []:  # trunk collision only; crowns are above head height
			var tcs := CollisionShape3D.new()
			tcs.shape = trunk_shape
			tcs.position = t.origin + Vector3.UP
			body.add_child(tcs)

	var all_bushes: Array = d.bushes  # no collision: the player walks through them
	for model in all_bushes.size():
		var list: Array[Transform3D] = all_bushes[model]
		if list.is_empty():
			continue
		var tints := PackedColorArray()
		for t in list:
			tints.append(seasons.leaf_color(BUSH_LEAVES[model / BUSH_VARIANTS], zone.position + t.origin))
		var mmi := _multimesh(bush_meshes[model], list, tints)
		mmi.set_meta("bushes", list)  # seasons.gd recolours them like trees
		zone.add_child(mmi)

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
		for t in list if body else []:
			var hcs := CollisionShape3D.new()
			hcs.shape = house_shapes[kind]
			hcs.transform = t * Transform3D(Basis(), house_centres[kind])
			body.add_child(hcs)

	var lamps: Array[Transform3D] = d.lamps
	if not lamps.is_empty():
		zone.add_child(_multimesh(lamp_meshes[0], lamps))
		var lanterns := _multimesh(lamp_meshes[1], lamps)
		lanterns.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		zone.add_child(lanterns)
		for t in lamps:
			var light := OmniLight3D.new()
			light.position = t * LAMP_LIGHT
			light.light_color = lamp_color
			light.light_energy = 1.6
			light.omni_range = 11.0
			light.omni_attenuation = 1.4
			# Shadows on houses, trees, posts and the player; only near the camera (cube maps cost
			# six renders each), and the whole light fades out past where its pool is a speck.
			light.shadow_enabled = true
			light.distance_fade_enabled = lamp_fade
			light.distance_fade_begin = 80.0
			light.distance_fade_length = 20.0
			light.distance_fade_shadow = LAMP_SHADOW_DIST
			light.visible = lamps_on
			light.add_to_group("lamp_light")
			zone.add_child(light)
			var lcs := CollisionShape3D.new()
			lcs.shape = lamp_shape
			lcs.position = t.origin + Vector3.UP * ((LAMP_HEIGHT + 0.6) / 2.0)
			body.add_child(lcs)  # lamps only exist in full zones, which have a body

	var all_props: Array = d.props  # full zones only, like the lamps
	for kind in all_props.size():
		var list: Array[Transform3D] = all_props[kind]
		if list.is_empty():
			continue
		zone.add_child(_multimesh(prop_meshes[kind], list))
		for t in list:
			var pcs := CollisionShape3D.new()
			pcs.shape = prop_shapes[kind]
			pcs.transform = t * Transform3D(Basis(), prop_centres[kind])
			body.add_child(pcs)

	var all_cats: Array = d.cats  # full zones only, on the benches; no collision (the bench has it)
	for pose in all_cats.size():
		if not all_cats[pose][0].is_empty():
			zone.add_child(_multimesh(cat_meshes[pose], all_cats[pose][0], PackedColorArray(all_cats[pose][1])))

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

	if zones.has(cell):  # rebuilt (density or detail): the old zone stays until this one is ready
		zones[cell].free()
	built[cell] = [d.density, d.detail]
	zone_trees[cell] = d.trees
	zones[cell] = zone
	add_child(zone)


## O: more or fewer trees, rocks and flowers. Loaded zones are rebuilt in the background, nearest first.
func set_density(d: float) -> void:
	density = d  # every built zone is now outdated (see _outdated)
	_update_hud()


## P: how far zones are generated and the fog ends (the fog start keeps each season's proportion).
func set_view_dist(d: float) -> void:
	view_dist = d
	seasons.env.fog_depth_end = d
	seasons.base.fog = d * FOG_START
	seasons.set_season(seasons.season)  # re-derives the season's fog start and re-applies the hour
	for cam in [player.camera, player.tp_cam]:
		cam.far = d + 50.0
	_update_hud()


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo:
		var dir := -1 if e.shift_pressed else 1
		if e.physical_keycode == KEY_O:
			set_density(_step(density, DENSITY_STEP * dir, DENSITY_STEP, DENSITY_MAX))
		elif e.physical_keycode == KEY_P:
			set_view_dist(_step(view_dist, VIEW_STEP * dir, VIEW_DIST, VIEW_MAX))


## `v + step`, wrapped into [lo, hi] (past one end → the other end).
static func _step(v: float, step: float, lo: float, hi: float) -> float:
	var n := snappedf(v + step, absf(step))
	return lo if n > hi + 0.001 else (hi if n < lo - 0.001 else n)


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


## Leaves (surface 1) get their own material, recoloured by seasons.gd; COLOR = baked shading ×
## MultiMesh instance colour (sRGB). Bark keeps its colour.
func _tintable_leaves(mesh: ArrayMesh) -> ArrayMesh:
	mesh.surface_set_material(1, mesh.surface_get_material(1).duplicate())
	return mesh


## Slight per-tree leaf colour shift: brightness ±15 %, yellower or bluer. Deterministic from position.
func leaf_tint(p: Vector3) -> Color:
	var h := hash(Vector2i(roundi(p.x * 10.0), roundi(p.z * 10.0)))
	var b := 0.85 + 0.3 * float(h & 0xFF) / 255.0
	var w := -0.08 + 0.18 * float((h >> 8) & 0xFF) / 255.0
	return Color(b * (1.0 + w), b, b * (1.0 - w))


func _ground_color(h: float, up: float) -> Color:
	if h < WATER_LEVEL + 1.5:
		return ground[0]  # sand / lakebed
	if up < 0.8:
		return ground[1]  # steep = rock
	if h > 22.0:
		return ground[2]  # peaks
	return ground[3]  # grass


## Baked terrain shading per vertex (`res` m grid), read by seasons.TERRAIN_SHADER as UV:
## x = meadow patch (-1 deep green dip .. 1 light yellow-green patch), y = light multiplier: hollows
## and slope feet darker, crests lighter, forest floor darker, and a soft contact shade round each of
## `objects` ([per-model transform lists, radius m at scale 1]) and `houses` (layout's near_houses).
## The broad terms are sampled on a SHADE_STEP m lattice in world coordinates and interpolated, so
## every detail level gets the same values at shared points. Deterministic, thread-safe.
func _shading(cell: Vector2i, res: int, mask: PackedByteArray, objects: Array, houses: Array) -> PackedVector2Array:
	var origin := Vector2(cell) * ZONE_SIZE
	var half := ZONE_SIZE / 2
	var m := ZONE_SIZE / SHADE_STEP + 1
	var b := HOLLOW_R / SHADE_STEP
	var g := m + 2 * b
	var lh := PackedFloat32Array()  # lattice heights with a HOLLOW_R border
	lh.resize(g * g)
	for z in g:
		for x in g:
			lh[z * g + x] = height(origin.x + (x - b) * SHADE_STEP - half, origin.y + (z - b) * SHADE_STEP - half)
	var light := PackedFloat32Array()
	var patch := PackedFloat32Array()
	for z in m:
		for x in m:
			var wx := origin.x + x * SHADE_STEP - half
			var wz := origin.y + z * SHADE_STEP - half
			var i := (z + b) * g + x + b
			var around := 0.0  # mean height of the 8 points HOLLOW_R away (square ring)
			for d in [-b, b]:
				around += lh[i + d] + lh[i + d * g] + lh[i + d * (g + 1)] + lh[i + d * (g - 1)]
			var hollow := around / 8.0 - lh[i]  # > 0 in a hollow or at the foot of a slope, < 0 on a crest
			var l := 1.0 - HOLLOW_DARK * smoothstep(0.0, 1.5, hollow) + CREST_LIGHT * smoothstep(0.0, 1.5, -hollow)
			var f := 0.0  # forest floor: where trees grow (tree_transforms' tests, bar the slope)
			if lh[i] > WATER_LEVEL + 2.0 and lh[i] < 20.0 and mask[z * SHADE_STEP * (ZONE_SIZE + 1) + x * SHADE_STEP] == FREE:
				f = smoothstep(0.0, 0.3, forest(wx, wz))
			light.append(l * (1.0 - FOREST_DARK * f))
			# Meadow patches ~120 m wide, broken up by smaller ones (~30 m); deep green under the trees.
			var p := noise.get_noise_2d(wx * 2.0 + 9000.0, wz * 2.0) * 1.6 + noise.get_noise_2d(wx * 8.0 - 3000.0, wz * 8.0) * 1.0
			patch.append(lerpf(clampf(p, -1.0, 1.0), -1.0, 0.7 * f))
	var n := ZONE_SIZE / res + 1
	var contact := PackedFloat32Array()
	contact.resize(n * n)
	contact.fill(1.0)
	for group in objects:
		for list in group[0]:
			for t: Transform3D in list:
				var r: float = group[1] * t.basis.x.length()
				# ponytail: no shade for objects whose shade would cross the zone edge (the neighbour can't
				# know them, half a blob would show); compute neighbours' placements if the gaps show.
				if absf(t.origin.x) > half - r or absf(t.origin.z) > half - r:
					continue
				var c := Vector2(t.origin.x, t.origin.z)
				for z in range(ceili((c.y - r + half) / res), floori((c.y + r + half) / res) + 1):
					for x in range(ceili((c.x - r + half) / res), floori((c.x + r + half) / res) + 1):
						var d2 := Vector2(x * res - half, z * res - half).distance_squared_to(c) / (r * r)
						if d2 < 1.0:
							contact[z * n + x] *= 1.0 - CONTACT * (1.0 - d2) * (1.0 - d2)
	for hs in houses:  # from the walls, balconies and porch (house_low) out to HOUSE_SHADE m
		var low: Rect2 = house_low[hs[2]]
		var rot := Basis(Vector3.UP, -hs[1])
		var c := Vector2(hs[0].x, hs[0].z) - origin
		var r: float = house_radius[hs[2]] + HOUSE_SHADE
		for z in range(maxi(ceili((c.y - r + half) / res), 0), mini(floori((c.y + r + half) / res), n - 1) + 1):
			for x in range(maxi(ceili((c.x - r + half) / res), 0), mini(floori((c.x + r + half) / res), n - 1) + 1):
				var l: Vector3 = rot * Vector3(x * res - half - c.x, 0, z * res - half - c.y)
				var q := Vector2(l.x, l.z)
				var d := 1.0 - minf(q.distance_to(q.clamp(low.position, low.end)) / HOUSE_SHADE, 1.0)
				contact[z * n + x] *= 1.0 - CONTACT * d * d
	var uvs := PackedVector2Array()
	var k := SHADE_STEP / res
	for z in n:
		var z0 := mini(z / k, m - 2)
		var fz := float(z - z0 * k) / k
		for x in n:
			var x0 := mini(x / k, m - 2)
			var fx := float(x - x0 * k) / k
			var i := z0 * m + x0
			var p := lerpf(lerpf(patch[i], patch[i + 1], fx), lerpf(patch[i + m], patch[i + m + 1], fx), fz)
			var l := lerpf(lerpf(light[i], light[i + 1], fx), lerpf(light[i + m], light[i + m + 1], fx), fz)
			uvs.append(Vector2(p, maxf(l * contact[z * n + x], SHADE_MIN)))
	return uvs


func _update_hud() -> void:
	hud.text = "ZQSD/WASD bouger · Shift courir · Espace sauter/remonter · Souris regarder · C caméra · M carte · Échap souris\n1-4 saison · +/- heure · O/Shift+O objets · P/Shift+P portée · N/Shift+N météo\nZones : %d · Saison : %s · Heure : %s · Objets ×%s · Portée : %d m\n%s" % [
		zones.size(), seasons.NAMES[seasons.season], daynight.clock(), density, view_dist, weather.label if weather else ""]


func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	# Haze = sky horizon colour; the ground half of the sky matches it so nothing shows past the fog.
	sky_mat.sky_top_color = seasons.colour("sky")
	sky_mat.sky_horizon_color = seasons.colour("haze")
	var haze := sky_mat.sky_horizon_color
	sky_mat.ground_horizon_color = haze
	sky_mat.ground_bottom_color = haze
	env.sky.sky_material = sky_mat
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = 1.0  # depth mode: opacity reached at fog_depth_end
	env.fog_light_color = haze
	env.fog_depth_begin = VIEW_DIST * FOG_START
	env.fog_depth_end = VIEW_DIST
	env.fog_sky_affect = 0.0
	# Soft light from the whole sky: shadows stay light and bluish, never black.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = AMBIENT
	var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	if compat:
		# Web/WebGL2 renderer over-brightens sky ambient and reflections; use a flat ambient of the
		# haze tinted by the sky (with COMPAT_SUN, matched by eye and by pixel to Forward+).
		# ponytail: hand-tuned against Forward+ screenshots, retune if lighting changes.
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = haze.lerp(sky_mat.sky_top_color, 0.35)
		env.ambient_light_energy = COMPAT_AMBIENT
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	# Filmic look: AgX keeps bright warm light from going flat yellow, then a gentle grade lifts the
	# shadows towards blue and warms the highlights (per-channel curves).
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_agx_contrast = COMPAT_AGX_CONTRAST if compat else AGX_CONTRAST
	env.adjustment_enabled = true
	env.adjustment_saturation = GRADE_SATURATION
	if not compat:  # Compatibility applies the curves far stronger (snow turned beige): saturation only there
		var curve := Gradient.new()
		curve.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
		curve.colors = PackedColorArray(GRADE)
		env.adjustment_color_correction = GradientTexture1D.new()
		env.adjustment_color_correction.gradient = curve
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_color = seasons.colour("sun")
	sun.light_energy = COMPAT_SUN if compat else SUN_ENERGY
	sun.shadow_enabled = true
	sun.shadow_opacity = SHADOW_OPACITY
	sun.shadow_blur = SHADOW_BLUR
	add_child(sun)
