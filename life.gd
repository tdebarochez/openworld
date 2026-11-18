extends Node
## Village life, built with the zones (world.gd calls zone_layout from layout() and attach from
## _attach_zone): chimney smoke, windows lit in the evening, laundry drying beside some houses, a forge
## in some villages, a flock of sheep or cows grazing in a meadow nearby. Placements are a pure function
## of the seed (village_life, memoised like world.village, each object owned by the zone holding its
## origin); everything moves in shaders driven by a few uniforms set here once a frame.

enum Animal { SHEEP, COW }
const ANIMAL_FILES := ["sheep", "cow"]  # tools/make_animals.py
# Per Animal: head count (min, max), spread round the flock's centre (m, σ), personal space (m).
const FLOCK := [[4, 8, 4.0, 1.5], [2, 5, 6.0, 2.8]]
const FLOCK_SHARE := 0.8  # villages with a flock…
const FLOCK_NEAR := 50.0  # …grazing this far from every village centre (past the clearings: ≤ ~45 m)…
const FLOCK_FAR := 100.0  # …but no farther from its own
const FLOCK_TRIES := 12
const MEADOW_FOREST := -0.25  # world.forest() under this is open grass, past the bushes (≥ -0.15)
const LAUNDRY_SHARE := 0.35  # houses with a washing line, along their left wall (the lamp is right of the door)
const LAUNDRY_LEN := 4.0  # m between the posts
const LAUNDRY_HEIGHT := 1.8  # m, the line above the lower post's foot
const FORGE_SHARE := 0.4  # villages with a forge, against the right wall of one house
const FORGE_SMOKE := Vector3(0, 3.25, -0.3)  # top of the forge's chimney, in its frame
const SMOKE_PUFFS := 7  # per chimney, rising one after the other
# Smoke: puffs rise, swell and fade (one cycle = PERIOD s), drifting downwind; each chimney smokes while
# `share` is above its own dice (INSTANCE_CUSTOM.r), so more or fewer houses smoke without a rebuild.
# Billboards built in view space (skip_vertex_transform), lit from above like the clouds.
const SMOKE_SHADER := """
shader_type spatial;
render_mode skip_vertex_transform, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 colour : source_color;
uniform float share = 0.5;
uniform vec3 wind = vec3(2.0, 0.0, 1.0);  // m drifted by the top of the plume
const float PERIOD = 7.0;
const float RISE = 6.0;
varying float alpha;
void vertex() {
	vec4 dice = INSTANCE_CUSTOM;
	float t = fract(TIME / PERIOD + UV2.x + dice.g);
	vec3 p = MODEL_MATRIX[3].xyz + vec3(0.0, t * RISE, 0.0) + wind * t * t;
	p.xz += 0.5 * t * vec2(sin(t * 7.0 + dice.g * 40.0), cos(t * 5.0 + dice.g * 30.0));
	VERTEX = (VIEW_MATRIX * vec4(p, 1.0)).xyz;
	float a = UV2.x * 9.0;  // each puff turned its own way, so the plume isn't a stack of discs
	VERTEX.xy += mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * (UV - 0.5) * vec2(1.0, 0.8) * mix(0.6, 3.0, sqrt(t));
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	alpha = smoothstep(dice.r, dice.r + 0.08, share) * smoothstep(0.0, 0.1, t) * (1.0 - t) * 0.75;
}
void fragment() {
	ALBEDO = colour;
	ALPHA = alpha * (1.0 - smoothstep(0.4, 1.0, length(UV - 0.5) * 2.0));
	ROUGHNESS = 1.0;
}
"""
# Lit windows: drawn over the house glass (next_pass, only from dusk to dawn), warm on the houses whose
# dice (INSTANCE_CUSTOM.r) are under `lit`, each a little warmer or paler (INSTANCE_CUSTOM.g).
const WINDOW_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, shadows_disabled;
uniform vec3 glow : source_color;
uniform float lit = 0.0;
uniform float energy = 1.1;
varying float on;
void vertex() {
	VERTEX += NORMAL * 0.004;
	on = step(INSTANCE_CUSTOM.r, lit) * mix(0.7, 1.2, INSTANCE_CUSTOM.g);
}
void fragment() {
	ALBEDO = glow * energy * on;
}
"""
# Washing: each cloth hangs from the line (y = 0) down to its hem (y = -1 before scaling) and billows
# more towards the hem; `shown` = 0 folds it away (rain, winter). COLOR = instance colour (sRGB).
const CLOTH_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform float shown = 1.0;
uniform float wind = 1.0;
void vertex() {
	float hang = clamp(-VERTEX.y, 0.0, 1.0);
	float t = TIME * 2.2 + dot(MODEL_MATRIX[3].xz, vec2(0.9, 1.7)) + VERTEX.x * 1.3;
	VERTEX.z += hang * hang * wind * (0.12 * sin(t) + 0.05 * sin(2.7 * t + 1.0));
	VERTEX *= shown;
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
}
"""
# Grazing (tools/make_animals.py): COLOR.a = 1 on the head and neck, turned down about X round the
# pivot (UV, model y/z) to the grass most of the time and up now and then, nibbling while down;
# 0 < COLOR.a <= 0.5 on the tail, flicked in bursts. Phases from the animal's position.
const ANIMAL_SHADER := """
shader_type spatial;
uniform vec3 albedo : source_color;
uniform float graze = 1.2;  // rad: the head down to the grass
void vertex() {
	float ph = dot(MODEL_MATRIX[3].xz, vec2(1.7, 2.3));
	if (COLOR.a > 0.75) {
		float down = smoothstep(-0.35, 0.05, sin(TIME * 0.21 + ph));
		float a = down * (graze - 0.05 + 0.05 * sin(TIME * 6.0 + ph));
		float c = cos(a);
		float s = sin(a);
		vec2 r = VERTEX.yz - UV;
		VERTEX.yz = UV + vec2(r.x * c - r.y * s, r.x * s + r.y * c);
		NORMAL.yz = vec2(NORMAL.y * c - NORMAL.z * s, NORMAL.y * s + NORMAL.z * c);
	} else if (COLOR.a > 0.0) {
		float burst = smoothstep(0.5, 0.9, sin(TIME * 0.6 + ph * 1.3));
		VERTEX.x += COLOR.a * 0.25 * burst * sin(TIME * 9.0 + ph);
	}
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
}
void fragment() {
	ALBEDO = albedo * COLOR.rgb;
	ROUGHNESS = 0.9;
}
"""

var world  # world.gd, set before setup()
var _life := {}  # memo of village_life
var animal_meshes: Array[ArrayMesh] = []  # per Animal
var animal_shapes: Array[BoxShape3D] = []  # per Animal: the body (head and tail excluded)
var animal_centres: Array[Vector3] = []
var smoke_mesh := ArrayMesh.new()
var smoke_mat := ShaderMaterial.new()
var window_mat := ShaderMaterial.new()
var glass_mats: Array[StandardMaterial3D] = []  # per house kind, its glass (slot 3): window_mat is its next pass
var chimneys: Array[Vector3] = []  # per house kind, the top of its chimney stack (house frame)
var laundry_mesh: ArrayMesh  # two posts and the line, the line along +Z from the origin
var cloth_mesh := ArrayMesh.new()
var cloth_mat := ShaderMaterial.new()
var cloth_colours: Array = []
var forge_mesh: ArrayMesh  # hearth with glowing coals and its chimney, the anvil on a stump in front (+Z)
var forge_shape := BoxShape3D.new()
var lit := 0.0  # share of houses with lit windows now
var smoking := 0.0  # share of chimneys smoking now
var laundry_out := true


## After world._init loaded the houses.
func setup() -> void:
	var s = world.seasons
	cloth_colours = s.colours(s.palette.laundry)
	smoke_mat.shader = _shader(SMOKE_SHADER)
	smoke_mat.set_shader_parameter("colour", s.colour("smoke"))
	window_mat.shader = _shader(WINDOW_SHADER)
	window_mat.set_shader_parameter("glow", s.colour("lamp"))
	cloth_mat.shader = _shader(CLOTH_SHADER)
	var shader := _shader(ANIMAL_SHADER)
	for file in ANIMAL_FILES:
		var m: ArrayMesh = world._load_mesh("res://assets/animals/%s.glb" % file)
		var body := AABB()
		var head := []
		var pivot := Vector2.ZERO
		for i in m.get_surface_count():
			var a := m.surface_get_arrays(i)
			var cols: PackedColorArray = a[Mesh.ARRAY_COLOR]
			for k in cols.size():
				var v: Vector3 = a[Mesh.ARRAY_VERTEX][k]
				if cols[k].a > 0.75:
					head.append(v)
					pivot = a[Mesh.ARRAY_TEX_UV][k]
				elif cols[k].a == 0.0:
					body = body.expand(v) if body.has_volume() else AABB(v, Vector3.ZERO)
		var graze := graze_angle(head, pivot)
		for i in m.get_surface_count():
			var mat := ShaderMaterial.new()
			mat.shader = shader
			mat.set_shader_parameter("albedo", (m.surface_get_material(i) as StandardMaterial3D).albedo_color)
			mat.set_shader_parameter("graze", graze)
			m.surface_set_material(i, mat)
		animal_meshes.append(m)
		var shape := BoxShape3D.new()
		shape.size = body.size
		animal_shapes.append(shape)
		animal_centres.append(body.get_center())
	for k in world.HOUSE_KINDS:
		var m: ArrayMesh = world.house_meshes[k]
		glass_mats.append(m.surface_get_material(3))
		# Chimney top: the highest stone (slot 4) vertices, the stack's four top corners (make_houses.py).
		var top := -INF
		var corners := []
		for v: Vector3 in m.surface_get_arrays(4)[Mesh.ARRAY_VERTEX]:
			if v.y > top + 0.01:
				top = v.y
				corners = [v]
			elif v.y > top - 0.01:
				corners.append(v)
		var c := Vector3.ZERO
		for v in corners:
			c += v / corners.size()
		chimneys.append(c + Vector3.UP * 0.2)  # above the cap
	_make_smoke()
	_make_laundry()
	_make_forge()


static func _shader(code: String) -> Shader:
	var sh := Shader.new()
	sh.code = code
	return sh


## Smallest angle (rad, ≤ 1.6) turning the head's lowest vertex down to 8 cm above the ground, rotating
## `head` (model space) about X round `pivot` (model y/z) the way ANIMAL_SHADER does.
static func graze_angle(head: Array, pivot: Vector2) -> float:
	for step in 81:
		var a := step * 0.02
		for v: Vector3 in head:
			var r := Vector2(v.y, v.z) - pivot
			if pivot.x + r.x * cos(a) - r.y * sin(a) < 0.08:
				return a
	return 1.6


## Share of houses with lit windows for the hour (sun height `sun_y`): none by day; most from dusk,
## going out one by one towards midnight, a few early risers before dawn.
static func windows_lit(hour: float, sun_y: float, on_below: float) -> float:
	if sun_y > on_below:
		return 0.0
	if hour > 12.0:
		return lerpf(0.72, 0.1, smoothstep(21.5, 24.0, hour))
	return lerpf(0.1, 0.45, smoothstep(4.5, 6.0, hour))


## Share of chimneys smoking: a few for the cooking on summer days, more in the evening, nearly all in
## winter, fewer in the small hours. Seasons in seasons.gd's Season order.
static func smoke_share(hour: float, season: int) -> float:
	var base: float = [0.3, 0.55, 0.85, 0.45][season]
	var evening := smoothstep(16.0, 18.5, hour) * (1.0 - smoothstep(22.0, 23.5, hour))
	var small_hours := 1.0 if hour < 5.5 or hour > 23.5 else 0.0
	return clampf(base + 0.35 * evening - 0.15 * small_hours, 0.1, 0.95)


## Washing is out unless it rains or snows, and never in winter.
static func washing_out(season: int, rain: float) -> bool:
	return season != 2 and rain < 0.05  # 2 = seasons.Season.WINTER


func _process(_delta: float) -> void:
	var dn = world.daynight
	var wx = world.weather
	if not dn or not wx:
		return
	var sun_y: float = dn.sun_dir(dn.time, dn.DECLINATION[world.seasons.season]).y
	var l := windows_lit(dn.time, sun_y, world.LAMP_ON_SUN)
	if l != lit:
		lit = l
		window_mat.set_shader_parameter("lit", l)
		for m in glass_mats:  # off by day: no second pass over every pane
			m.next_pass = window_mat if l > 0.0 else null
	smoking = smoke_share(dn.time, world.seasons.season)
	smoke_mat.set_shader_parameter("share", smoking)
	smoke_mat.set_shader_parameter("wind", Vector3(wx.wind.x, 0.0, wx.wind.y) * (2.0 + 4.0 * wx.rain + 2.0 * wx.overcast))
	var out := washing_out(world.seasons.season, wx.rain)
	if out != laundry_out:
		laundry_out = out
		cloth_mat.set_shader_parameter("shown", 1.0 if out else 0.0)
	cloth_mat.set_shader_parameter("wind", 1.0 + 1.5 * wx.overcast)


## Per house of a zone (zone-local transforms, zone at `origin`): [window dice, warmth, smoke dice,
## smoke phase] as MultiMesh custom data, hashed from the house's world position.
func house_dice(origin: Vector3, houses: Array[Transform3D]) -> PackedColorArray:
	var out := PackedColorArray()
	for t in houses:
		var h := hash(Vector3i(roundi(origin.x + t.origin.x), roundi(origin.z + t.origin.z), 23))
		out.append(Color(float(h & 0xFF) / 256.0, float((h >> 8) & 0xFF) / 255.0, float((h >> 16) & 0xFF) / 256.0,
			float((h >> 24) & 0x7F) / 127.0))
	return out


## Laundry, forge and flock of village `g`, from their own dice (nothing else in the village moves):
## {"laundry": [[post a, post b (world, on the ground), cloths [[width, drop, colour index]]]],
## "forge": [world position, yaw] or [], "flock": {"kind": Animal, "animals": [[world position, yaw]]}
## or {}}; {} without a village. Pure function of the seed, memoised (thread-safe).
func village_life(g: Vector2i) -> Dictionary:
	return world._memo(_life, g, _village_life.bind(g))


func _village_life(g: Vector2i) -> Dictionary:
	var v: Dictionary = world.village(g)
	if v.is_empty():
		return {}
	var c: Vector2 = v.centre
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(world.village_site(g).seed + 7)
	var roads: Array = world._roads_near(c, FLOCK_FAR + 10.0)
	var taken: Array = v.lamps + v.props  # [world position, …]
	var laundry := []
	for hs in v.houses:
		var dice := rng.randf()
		var cloths := []
		for i in rng.randi_range(3, 5):
			cloths.append([rng.randf_range(0.45, 0.9), rng.randf_range(0.45, 0.8), rng.randi() % cloth_colours.size()])
		var low: Rect2 = world.house_low[hs[2]]
		var rot := Basis(Vector3.UP, hs[1])
		var x := low.position.x - 1.6
		var a: Vector3 = hs[0] + rot * Vector3(x, 0, low.get_center().y - LAUNDRY_LEN / 2.0)
		var b: Vector3 = hs[0] + rot * Vector3(x, 0, low.get_center().y + LAUNDRY_LEN / 2.0)
		var pts := range(5).map(func(i): return Vector2(a.x, a.z).lerp(Vector2(b.x, b.z), i / 4.0))
		if dice < LAUNDRY_SHARE and absf(world.height(a.x, a.z) - world.height(b.x, b.z)) < 0.4 \
				and pts.all(func(p): return _free(p, v.houses, roads, taken, 0.4)):
			a.y = world.height(a.x, a.z)
			b.y = world.height(b.x, b.z)
			laundry.append([a, b, cloths])
			taken.append_array(pts.map(func(p): return [Vector3(p.x, 0, p.y)]))
	var forge := []
	var start := rng.randi()
	if rng.randf() < FORGE_SHARE:
		for k in v.houses.size():
			var hs: Array = v.houses[(start + k) % v.houses.size()]
			var rot := Basis(Vector3.UP, hs[1])
			var low: Rect2 = world.house_low[hs[2]]
			var p: Vector3 = hs[0] + rot * Vector3(low.end.x + 0.75, 0, low.get_center().y)
			var yaw: float = hs[1] + PI / 2.0  # the forge's +Z = the house's +X: hearth to the wall, anvil out
			var fr := Basis(Vector3.UP, yaw)
			var pts := [Vector3.ZERO, Vector3(0.75, 0, 0), Vector3(-0.75, 0, 0), Vector3(0, 0, 1.4)].map(
				func(o): return Vector2((p + fr * o).x, (p + fr * o).z))
			if pts.all(func(q): return _free(q, v.houses, roads, taken, 0.15)):
				forge = [Vector3(p.x, world.height(p.x, p.z), p.z), yaw]
				break
	var flock := {}
	var kind := Animal.SHEEP if rng.randf() < 0.55 else Animal.COW
	var spec: Array = FLOCK[kind]
	var count := rng.randi_range(spec[0], spec[1])
	var want := rng.randf() < FLOCK_SHARE
	for i in FLOCK_TRIES:
		var p := c + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(FLOCK_NEAR, FLOCK_FAR)
		var heading := rng.randf() * TAU  # a flock grazes facing roughly one way
		var spots := []
		for j in count:
			spots.append([rng.randfn(0.0, spec[2]), rng.randfn(0.0, spec[2]), rng.randfn(0.0, 0.7)])
		if not want or not meadow(p, roads):
			continue
		var animals := []
		for s in spots:
			var q: Vector2 = p + Vector2(s[0], s[1])
			if meadow(q, roads) and animals.all(func(o): return Vector2(o[0].x, o[0].z).distance_to(q) >= spec[3]):
				animals.append([Vector3(q.x, world.height(q.x, q.y), q.y), heading + s[2]])
		if animals.size() >= spec[0]:
			flock = {"kind": kind, "animals": animals}
			break
	return {"laundry": laundry, "forge": forge, "flock": flock}


## World x/z point `p` clear of houses (by `margin`), roads, lamps and props (`taken`) and water.
func _free(p: Vector2, houses: Array, roads: Array, taken: Array, margin: float) -> bool:
	return not world.in_house(p, houses, margin) and not world._near_line(p, roads, world.ROAD_HALF + 1.0) \
		and world._far_from(p, taken, 1.2) and world.height(p.x, p.y) > world.WATER_LEVEL + 0.5


## Open grass for grazing: dry, below the tree line, gentle, out of the woods and their bushy edge, off
## the roads and past every village's clearing.
func meadow(p: Vector2, roads: Array) -> bool:
	var h: float = world.height(p.x, p.y)
	if h < world.WATER_LEVEL + 2.5 or h > world.TREE_LINE or world._normal(p.x, p.y).y < 0.95 \
			or world.forest(p.x, p.y) > MEADOW_FOREST or world._near_line(p, roads, world.ROAD_HALF + 3.0):
		return false
	var g := Vector2i((p / world.VILLAGE_GRID).floor())
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var s: Dictionary = world.village_site(g + Vector2i(dx, dz))
			if not s.is_empty() and s.centre.distance_to(p) < FLOCK_NEAR:
				return false
	# Nor on a landmark's cleared ground (a windmill stands 80-130 m from a village, like the flocks).
	var ls: Dictionary = world.landmark_site(Vector2i((p / world.LANDMARK_GRID).floor()))
	return ls.is_empty() or Vector2(ls.pos.x, ls.pos.z).distance_to(p) > world.LANDMARK_CLEAR[ls.kind] + 4.0


## Zone `cell`'s share of village life (zone-local transforms, each thing in the zone holding its
## origin), clearing their ground in `mask` (no tree, rock or wild flower under them). Thread-safe.
func zone_layout(cell: Vector2i, mask: PackedByteArray) -> Dictionary:
	var origin: Vector2 = Vector2(cell) * world.ZONE_SIZE
	var o3 := Vector3(origin.x, 0, origin.y)
	var reach: float = world.ZONE_SIZE / 2.0 + FLOCK_FAR + 15.0
	var laundry: Array[Transform3D] = []
	var cloths: Array[Transform3D] = []
	var colours := PackedColorArray()
	var forges: Array[Transform3D] = []
	var animals := []
	for k in Animal.size():
		animals.append([] as Array[Transform3D])
	var grid: float = world.VILLAGE_GRID
	for gx in range(floori((origin.x - reach) / grid), floori((origin.x + reach) / grid) + 1):
		for gz in range(floori((origin.y - reach) / grid), floori((origin.y + reach) / grid) + 1):
			var life := village_life(Vector2i(gx, gz))
			if life.is_empty():
				continue
			for line in life.laundry:
				var a: Vector3 = line[0]
				var b: Vector3 = line[1]
				world._mark_segment(mask, Vector2(a.x, a.z) - origin, Vector2(b.x, b.z) - origin, -1.0, 1.2)
				if world.cell_of(a) != cell:
					continue
				var frame := Transform3D(Basis(Vector3.UP, atan2(b.x - a.x, b.z - a.z)), Vector3(a.x, minf(a.y, b.y), a.z) - o3)
				laundry.append(frame)
				var total: float = line[2].reduce(func(s, cl): return s + cl[0] + 0.15, -0.15)
				var z := (LAUNDRY_LEN - total) / 2.0
				for cl in line[2]:
					var t := Transform3D(Basis(Vector3.UP, PI / 2.0) * Basis.from_scale(Vector3(cl[0], cl[1], 1.0)),
						Vector3(0, LAUNDRY_HEIGHT - 0.02, z + cl[0] / 2.0))
					cloths.append(frame * t)
					colours.append(cloth_colours[cl[2]])
					z += cl[0] + 0.15
			if not life.forge.is_empty():
				var f: Vector3 = life.forge[0]
				world._mark_segment(mask, Vector2(f.x, f.z) - origin, Vector2(f.x, f.z) - origin, -1.0, 2.5)
				if world.cell_of(f) == cell:
					forges.append(Transform3D(Basis(Vector3.UP, life.forge[1]), f - o3))
			if not life.flock.is_empty():
				for an in life.flock.animals:
					var p: Vector3 = an[0]
					world._mark_segment(mask, Vector2(p.x, p.z) - origin, Vector2(p.x, p.z) - origin, -1.0, FLOCK[life.flock.kind][3] + 1.0)
					if world.cell_of(p) == cell:
						var tilt := Basis(Quaternion(Vector3.UP, world._normal(p.x, p.z)))  # stands on the slope
						animals[life.flock.kind].append(Transform3D(tilt * Basis(Vector3.UP, an[1]), p - o3 + Vector3.DOWN * 0.03))
	return {"laundry": laundry, "cloths": cloths, "cloth_colours": colours, "forges": forges, "animals": animals}


## Main thread, from world._attach_zone: smoke over the zone's chimneys (every detail level, like the
## houses), and in full zones (`d.life`, with `body` for collision) laundry, forges and animals.
func attach(zone: Node3D, d: Dictionary, body: StaticBody3D) -> void:
	var life: Dictionary = d.get("life", {})
	var tops: Array[Transform3D] = []
	var dice := PackedColorArray()
	for kind in d.houses.size():
		var list: Array[Transform3D] = d.houses[kind]
		var hd := house_dice(zone.position, list)
		for i in list.size():
			tops.append(Transform3D(Basis(), list[i] * chimneys[kind]))
			dice.append(Color(hd[i].b, hd[i].a, 0, 0))
	for t: Transform3D in life.get("forges", []):
		tops.append(Transform3D(Basis(), t * FORGE_SMOKE))
		dice.append(Color(0, fposmod(t.origin.x * 0.37, 1.0), 0, 0))  # always lit
	if not tops.is_empty():
		var smoke: MultiMeshInstance3D = world._multimesh(smoke_mesh, tops, PackedColorArray(), dice)
		smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		zone.add_child(smoke)
	if life.is_empty():
		return
	if not life.laundry.is_empty():
		zone.add_child(world._multimesh(laundry_mesh, life.laundry))
		var cl: MultiMeshInstance3D = world._multimesh(cloth_mesh, life.cloths, life.cloth_colours)
		cl.material_override = cloth_mat
		zone.add_child(cl)
	if not life.forges.is_empty():
		zone.add_child(world._multimesh(forge_mesh, life.forges))
		for t: Transform3D in life.forges:
			_collide(body, forge_shape, t * Transform3D(Basis(), forge_mesh.get_aabb().get_center()))
	for kind in life.animals.size():
		var list: Array[Transform3D] = life.animals[kind]
		if list.is_empty():
			continue
		zone.add_child(world._multimesh(animal_meshes[kind], list))
		for t in list:
			_collide(body, animal_shapes[kind], t * Transform3D(Basis(), animal_centres[kind]))


static func _collide(body: StaticBody3D, shape: Shape3D, t: Transform3D) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = t
	body.add_child(cs)


## SMOKE_PUFFS camera-facing quads, all at the chimney (the shader moves them): UV = corner, UV2.x =
## the puff's phase.
func _make_smoke() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	for k in SMOKE_PUFFS:
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			verts.append(Vector3.ZERO)
			uvs.append(corner)
			uv2s.append(Vector2(float(k) / SMOKE_PUFFS, 0))
		idx.append_array([k * 4, k * 4 + 1, k * 4 + 2, k * 4, k * 4 + 2, k * 4 + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	smoke_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	smoke_mesh.surface_set_material(0, smoke_mat)
	smoke_mesh.custom_aabb = AABB(Vector3(-8, -1, -8), Vector3(16, 10, 16))  # the plume, wherever the wind takes it


## Boxes ([size, centre]) in `parts` ([[boxes, material]]) as one mesh, a surface per material.
static func _boxes(parts: Array) -> ArrayMesh:
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
	return mesh


func _mat(colour: String) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = world.seasons.colour(colour)
	m.roughness = 0.9
	return m


## Two posts (sunk 0.5 m for uneven ground) and the line between them; cloths: a 1 m square hanging
## from y = 0, subdivided down its length so it can billow.
func _make_laundry() -> void:
	var post := Vector3(0.08, LAUNDRY_HEIGHT + 0.6, 0.08)
	var py := (LAUNDRY_HEIGHT + 0.1 - 0.5) / 2.0
	laundry_mesh = _boxes([[[[post, Vector3(0, py, 0)], [post, Vector3(0, py, LAUNDRY_LEN)]], _mat("bark")],
		[[[Vector3(0.015, 0.015, LAUNDRY_LEN), Vector3(0, LAUNDRY_HEIGHT, LAUNDRY_LEN / 2.0)]], _mat("cream")]])
	var plane := PlaneMesh.new()
	plane.orientation = PlaneMesh.FACE_Z
	plane.size = Vector2.ONE
	plane.subdivide_width = 2
	plane.subdivide_depth = 4
	plane.center_offset = Vector3(0, -0.5, 0)
	cloth_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plane.get_mesh_arrays())  # an ArrayMesh like the others


## Hearth (stone, glowing coals) with a hood and chimney at the back (-Z), anvil on a stump in front.
func _make_forge() -> void:
	var ember := _mat("ember")
	ember.emission_enabled = true
	ember.emission = world.seasons.colour("ember")
	ember.emission_energy_multiplier = 2.0
	forge_mesh = _boxes([
		[[[Vector3(1.4, 0.9, 1.0), Vector3(0, 0.35, 0)], [Vector3(0.7, 2.4, 0.45), Vector3(0, 2.0, -0.3)],
			[Vector3(1.2, 0.3, 0.75), Vector3(0, 1.75, -0.12)]], _mat("stone")],
		[[[Vector3(1.0, 0.06, 0.55), Vector3(0, 0.82, 0.12)]], ember],
		[[[Vector3(0.45, 0.5, 0.45), Vector3(0, 0.2, 1.4)]], _mat("bark")],
		[[[Vector3(0.6, 0.18, 0.22), Vector3(0, 0.54, 1.4)], [Vector3(0.22, 0.1, 0.12), Vector3(0.4, 0.56, 1.4)]], _mat("ink")]])
	forge_shape.size = forge_mesh.get_aabb().size
