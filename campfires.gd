extends Node
## Campfires in forest clearings far from the villages (tools/make_campfire.py: a ring of stones, logs and
## embers, seats round it), built with the zones like life.gd (world.gd calls zone_layout from layout()
## and attach from _attach_zone). At most one per GRID square, a pure function of the seed (camp_site,
## memoised like world.landmark_site), owned by the zone holding its centre, its ground cleared in the
## layout mask. Flames and sparks are camera-facing cards animated in FLAME_SHADER, the smoke is
## life.gd's chimney smoke (a copy of its material, dimmer at night): one MultiMesh each per zone, no
## script per fire. Full zones add the camp
## model (trimesh collision) and a warm OmniLight per fire, in the "lamp_light" group so it comes on
## and fades out with the street lamps; _process flickers those few lights.
##
## The fires always burn (someone camps there; the smoke shows where by day, the glow by night): lower
## flames by day, full ones with the light from dusk to dawn. Rain doesn't put them out (a fire found
## dead in every shower would be a let-down) but beats them down: lower flames, dimmer light and embers.

const KINDS := 3  # tools/make_campfire.py: campfire_0..2
const GRID := 256.0  # one candidate per square…
const MARGIN := 40.0  # …kept this far inside it, so two fires are ≥ 80 m apart
const TRIES := 48  # spots tried per square
const FAR := 300.0  # m from every village centre
const CLEAR := 5.5  # m kept free of trees, bushes, rocks and flowers round the fire (the camp reaches 2.1 m)
const DIRT := 1.8  # m of trodden earth (the layout's ROAD colour) round the hearth
const ROAD_GAP := 10.0  # m of woods at least between the clearing and a road
const OPEN := 0.1  # world.forest() at the fire at least: inside the woods (0 = their edge), not in a meadow
const RING := 12.0  # m: the woods round the clearing are sampled this far out…
const WOODED := 7  # …at 8 points, at least this many of them under trees
const FLAT := 0.45  # m the ground may vary within the camp's reach
const LIGHT_AT := Vector3(0, 0.7, 0)  # in the flames: high enough that the ring of stones throws a short
# shadow only, under campfire_2's pot (0.86 m up; inside it, it would light nothing)
const LIGHT_ENERGY := 2.2
const LIGHT_RANGE := 10.0
const LIGHT_SHADOW_DIST := 25.0  # m from the camera within which a fire casts shadows
const SMOKE_AT := Vector3(0, 0.9, 0)
const DAY_FLAMES := 0.7  # flame height by day (1 at night)
# Flames: three tongues and a few sparks per fire (_make_flame), all at the fire's centre and turned to
# face the camera about the vertical (they stay upright from above). Vertex COLOR: r = width, g = height
# (m), b = 1 for a spark; UV = corner, UV2.x = phase. Additive and unshaded, so they glow by night and
# past the bloom threshold; fog_disabled (fog on an additive card adds the haze colour: a pale ghost
# far away) and faded out by `fade_end` instead.
const FLAME_SHADER := """
shader_type spatial;
render_mode skip_vertex_transform, unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec3 core : source_color;
uniform vec3 tip : source_color;
uniform float size = 1.0;  // flame height (lower by day and in the rain)
uniform float energy = 1.6;
uniform float fade_end = 200.0;  // m: gone by here (the depth fog's end)
varying float ph;
varying float glow;
varying float spark;
void vertex() {
	vec3 c = MODEL_MATRIX[3].xyz;
	ph = fract(dot(c.xz, vec2(0.71, 1.37))) * 40.0 + UV2.x * 6.283;
	vec3 back = INV_VIEW_MATRIX[2].xyz;  // towards the camera
	vec3 right = cross(vec3(0.0, 1.0, 0.0), back);
	right = length(right) > 1e-3 ? normalize(right) : INV_VIEW_MATRIX[0].xyz;
	spark = COLOR.b;
	vec3 p;
	if (spark > 0.5) {  // rises a couple of metres, wandering, and dies out
		float t = fract(TIME * 0.55 + UV2.x * 0.618 + fract(ph * 0.1));
		p = c + VERTEX + vec3(0.2 * sin(t * 6.0 + ph), t * 2.2 * size + 0.2, 0.2 * cos(t * 5.0 + ph * 1.3));
		p += (right * (UV.x - 0.5) + vec3(0.0, UV.y - 0.5, 0.0)) * COLOR.r * (1.0 - t);
		glow = energy * 2.0 * (1.0 - t) * step(0.35, fract(UV2.x * 7.3 + floor(TIME * 0.55 + UV2.x * 0.618) * 0.37));
	} else {
		float h = COLOR.g * size * (0.85 + 0.1 * sin(TIME * 8.3 + ph) + 0.05 * sin(TIME * 17.0 + ph * 2.0));
		p = c + VERTEX + right * (UV.x - 0.5) * COLOR.r * mix(1.0, size, 0.5) + vec3(0.0, UV.y * h, 0.0);
		glow = energy;
	}
	VERTEX = (VIEW_MATRIX * vec4(p, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(back, 0.0)).xyz);
	glow *= 1.0 - smoothstep(fade_end * 0.5, fade_end, length(VERTEX));
}
void fragment() {
	if (spark > 0.5) {
		ALBEDO = mix(tip, core, 0.5) * glow;
		ALPHA = 1.0 - smoothstep(0.25, 0.5, length(UV - 0.5));
	} else {
		float y = UV.y;
		float x = UV.x * 2.0 - 1.0 - y * (0.22 * sin(TIME * 6.1 + ph + y * 4.0) + 0.08 * sin(TIME * 13.7 + ph * 1.7 + y * 9.0));
		float w = pow(clamp(1.0 - y, 0.0, 1.0), 0.8) * clamp(y * 4.0 + 0.45, 0.0, 1.0);  // teardrop
		float body = 1.0 - smoothstep(0.45 * w, w, abs(x));
		float heat = (1.0 - smoothstep(0.0, 0.6 * w + 0.01, abs(x))) * (1.0 - y);  // white-hot low in the middle
		ALBEDO = mix(tip, core, clamp(heat * 1.8, 0.0, 1.0)) * glow * (0.55 + heat);
		ALPHA = body;
	}
}
"""

var world  # world.gd, set before setup()
var _sites := {}  # memo of camp_site
var meshes: Array[ArrayMesh] = []  # per kind
var shapes: Array[Shape3D] = []  # per kind, trimesh
var ember_mat: StandardMaterial3D  # the embers of every kind, glowing
var flame_mesh := ArrayMesh.new()
var flame_mat := ShaderMaterial.new()
var smoke_mat: ShaderMaterial  # life.gd's chimney smoke, dimmer at night (a pale column right by the camera)
var light_color: Color
var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"


## After world._init loaded its models (and life.setup made the smoke).
func setup() -> void:
	var s = world.seasons
	for k in KINDS:
		var m: ArrayMesh = world._load_mesh("res://assets/campfires/campfire_%d.glb" % k)
		for i in m.get_surface_count():
			if m.surface_get_material(i).resource_name.ends_with("_ember"):
				if not ember_mat:
					ember_mat = m.surface_get_material(i)
					ember_mat.emission_enabled = true
					ember_mat.emission = s.colour("ember")
				m.surface_set_material(i, ember_mat)
		meshes.append(m)
		shapes.append(m.create_trimesh_shape())
	light_color = s.colour("ember").lerp(s.colour("lamp"), 0.5)
	flame_mat.shader = Shader.new()
	flame_mat.shader.code = FLAME_SHADER
	flame_mat.set_shader_parameter("core", s.colour("flame"))
	flame_mat.set_shader_parameter("tip", s.colour("ember"))
	_make_flame()
	smoke_mat = world.life.smoke_mat.duplicate()
	_set_fire(0.0, 0.0)


## Camp of the GRID square `g`, or {}: {"pos": world position (the fire's centre, on the ground), "yaw",
## "kind"}. Pure function of the seed, memoised (thread-safe).
func camp_site(g: Vector2i) -> Dictionary:
	return world._memo(_sites, g, _camp_site.bind(g))


func _camp_site(g: Vector2i) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(world.noise.seed + 9, g.x, g.y))
	var kind := rng.randi() % KINDS
	var yaw := rng.randf() * TAU
	var inner := Rect2(Vector2(g) * GRID, Vector2.ONE * GRID).grow(-MARGIN)
	var roads: Array = world._roads_near(inner.get_center(), GRID * 0.75)
	for i in TRIES:
		var p := inner.position + Vector2(rng.randf(), rng.randf()) * inner.size
		if clearing(p, roads):
			return {"pos": Vector3(p.x, world.height(p.x, p.y) - 0.03, p.y), "yaw": yaw, "kind": kind}
	return {}


## A camp fits at world x/z `p`: dry flat ground below the tree line in or at the edge of the woods,
## woods all round, CLEAR + ROAD_GAP off `roads`, FAR from every village, clear of cabins and landmarks.
func clearing(p: Vector2, roads: Array) -> bool:
	var h: float = world.height(p.x, p.y)
	if h < world.WATER_LEVEL + 3.0 or h > world.TREE_LINE - 4.0 or world.forest(p.x, p.y) < OPEN:
		return false
	var g: Vector2 = world._ground_range(p, 2.2)
	if g.y - g.x > FLAT or world._normal(p.x, p.y).y < 0.95:
		return false
	var wooded := 0
	for i in 8:
		wooded += int(woods(p + Vector2.from_angle(TAU * i / 8.0) * RING))
	if wooded < WOODED or not world._landmark_clear(p, CLEAR + ROAD_GAP, roads, FAR):
		return false
	var lg := Vector2i((p / world.LANDMARK_GRID).floor())
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var ls: Dictionary = world.landmark_site(lg + Vector2i(dx, dz))
			if ls.is_empty():
				continue
			var r: float = world.LANDMARK_CLEAR[ls.kind] + (world.BRIDGE_END * ls.scale if ls.kind == world.Landmark.BRIDGE else 0.0)
			if Vector2(ls.pos.x, ls.pos.z).distance_to(p) < r + CLEAR + ROAD_GAP:
				return false
	return true


## Trees grow at world x/z `q` (tree_transforms' tests, the layout mask aside).
func woods(q: Vector2) -> bool:
	var h: float = world.height(q.x, q.y)
	return world.forest(q.x, q.y) > 0.05 and h > world.WATER_LEVEL + 2.0 and h < world.TREE_LINE and world._normal(q.x, q.y).y > 0.85


## The camp's transform (world): its model turned by its yaw.
static func camp_transform(s: Dictionary) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, s.yaw), s.pos)


## Zone `cell`'s camps per kind (zone-local transforms, each in the zone holding its centre), clearing
## their ground in `mask` (trodden earth round the hearth). Thread-safe.
func zone_layout(cell: Vector2i, mask: PackedByteArray) -> Array:
	var origin: Vector2 = Vector2(cell) * world.ZONE_SIZE
	var reach: float = world.ZONE_SIZE / 2.0 + CLEAR + 1.0
	var out := []
	for k in KINDS:
		out.append([] as Array[Transform3D])
	for gx in range(floori((origin.x - reach) / GRID), floori((origin.x + reach) / GRID) + 1):
		for gz in range(floori((origin.y - reach) / GRID), floori((origin.y + reach) / GRID) + 1):
			var s := camp_site(Vector2i(gx, gz))
			if s.is_empty():
				continue
			var lp := Vector2(s.pos.x, s.pos.z) - origin
			world._mark_segment(mask, lp, lp, DIRT, CLEAR)
			if world.cell_of(s.pos) == cell:
				out[s.kind].append(camp_transform(s).translated(-Vector3(origin.x, 0, origin.y)))
	return out


## The camp's centre nearest to `p` within `r` m, raised to the flames, or null.
func nearest(p: Vector3, r: float):
	var best = null
	for gx in range(floori((p.x - r) / GRID), floori((p.x + r) / GRID) + 1):
		for gz in range(floori((p.z - r) / GRID), floori((p.z + r) / GRID) + 1):
			var s := camp_site(Vector2i(gx, gz))
			if not s.is_empty() and s.pos.distance_to(p) < r:
				r = s.pos.distance_to(p)
				best = s.pos + Vector3.UP * 0.5
	return best


## Main thread, from world._attach_zone: flames and smoke at every detail level (a glow and a wisp seen
## from afar), the camp, its collision (`body`) and its light in full zones.
func attach(zone: Node3D, d: Dictionary, body: StaticBody3D) -> void:
	var fires: Array[Transform3D] = []
	var camps: Array = d.get("camps", [])
	for k in camps.size():
		var list: Array[Transform3D] = camps[k]
		for t in list:
			fires.append(Transform3D(Basis(), t.origin))
		if list.is_empty() or d.detail != world.Detail.FULL:
			continue
		zone.add_child(world._multimesh(meshes[k], list))
		for t in list:
			world.life._collide(body, shapes[k], t)
	if fires.is_empty():
		return
	var flames: MultiMeshInstance3D = world._multimesh(flame_mesh, fires)
	flames.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	zone.add_child(flames)
	var tops: Array[Transform3D] = []
	var dice := PackedColorArray()
	for t in fires:
		tops.append(t.translated(SMOKE_AT))
		dice.append(Color(0, fposmod((zone.position.x + t.origin.x) * 0.37, 1.0), 0, 0))  # always smoking
	var smoke: MultiMeshInstance3D = world._multimesh(world.life.smoke_mesh, tops, PackedColorArray(), dice)
	smoke.material_override = smoke_mat
	smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	zone.add_child(smoke)
	if d.detail != world.Detail.FULL:
		return
	for t in fires:
		var light := OmniLight3D.new()
		light.position = t.origin + LIGHT_AT
		light.light_color = light_color
		light.light_energy = LIGHT_ENERGY
		light.omni_range = LIGHT_RANGE
		light.omni_attenuation = 1.3
		# Shadows of the seats, the hen, the trunks round the clearing, only near the camera; not in
		# Compatibility (web), where the cube map's six passes cost ~3 ms a frame by the fire (~1 ms in Forward+).
		light.shadow_enabled = not compat
		light.distance_fade_enabled = world.lamp_fade
		light.distance_fade_begin = 60.0
		light.distance_fade_length = 20.0
		light.distance_fade_shadow = LIGHT_SHADOW_DIST
		light.visible = world.lamps_on
		light.set_meta("phase", fposmod((zone.position.x + t.origin.x) * 1.7 + (zone.position.z + t.origin.z) * 2.3, TAU))
		light.add_to_group("lamp_light")  # on, off and faded with the street lamps (world.set_lamps, set_lamp_fade)
		light.add_to_group("camp_light")
		zone.add_child(light)


## Light energy factor of a fire at time `t` (s), phase `ph`: a few incommensurate waves, in [0.72, 1.12].
static func flicker(t: float, ph: float) -> float:
	return 0.92 + 0.1 * sin(t * 7.7 + ph) + 0.06 * sin(t * 13.1 + ph * 1.7) + 0.04 * sin(t * 23.3 + ph * 0.3)


## Flames, embers and the light's base energy for the night share `night` (0 by day .. 1) and `rain`.
func _set_fire(night: float, rain: float) -> void:
	var damp := 1.0 - 0.4 * rain
	flame_mat.set_shader_parameter("size", lerpf(DAY_FLAMES, 1.0, night) * (1.0 - 0.3 * rain))
	flame_mat.set_shader_parameter("energy", lerpf(1.2, 1.7, night) * damp)
	ember_mat.emission_energy_multiplier = lerpf(1.5, 3.0, night) * damp


func _process(_delta: float) -> void:
	var dn = world.daynight
	var wx = world.weather
	if not dn or not wx:
		return
	var sun_y: float = dn.sun_dir(dn.time, dn.DECLINATION[world.seasons.season]).y
	var night := smoothstep(world.LAMP_ON_SUN + 0.1, world.LAMP_ON_SUN - 0.1, sun_y)
	_set_fire(night, wx.rain)
	flame_mat.set_shader_parameter("fade_end", world.view_dist)
	var haze: Color = world.seasons.sky.sky_horizon_color  # as life.gd tints its smoke
	smoke_mat.set_shader_parameter("light", Vector3(haze.r, haze.g, haze.b) * world.life.SMOKE_LIGHT * lerpf(1.0, 0.45, night))
	smoke_mat.set_shader_parameter("wind", Vector3(wx.wind.x, 0.0, wx.wind.y) * (2.0 + 4.0 * wx.rain + 2.0 * wx.overcast))
	if not world.lamps_on:
		return
	var t := Time.get_ticks_msec() / 1000.0
	var e: float = LIGHT_ENERGY * (1.0 - 0.4 * wx.rain) * smoothstep(world.LAMP_ON_SUN, world.LAMP_ON_SUN - 0.1, sun_y)
	for light: OmniLight3D in get_tree().get_nodes_in_group("camp_light"):
		light.light_energy = e * flicker(t, light.get_meta("phase"))


## Three flame tongues (the big one in the middle, two smaller ones beside it) and six sparks, each a
## quad collapsed on its base point; FLAME_SHADER spreads and moves them.
func _make_flame() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var parts := [[Vector3(0, 0.08, 0), 0.62, 1.0, 0.0], [Vector3(-0.13, 0.06, 0.07), 0.42, 0.72, 0.0],
		[Vector3(0.14, 0.06, -0.06), 0.4, 0.8, 0.0]]
	for k in 6:
		parts.append([Vector3(0.1 * cos(k * 2.4), 0.3, 0.1 * sin(k * 2.4)), 0.05, 0.0, 1.0])
	for k in parts.size():
		var part: Array = parts[k]
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			verts.append(part[0])
			uvs.append(corner)
			uv2s.append(Vector2(float(k) / parts.size(), 0))
			cols.append(Color(part[1], part[2], part[3]))
		idx.append_array([k * 4, k * 4 + 1, k * 4 + 2, k * 4, k * 4 + 2, k * 4 + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	flame_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	flame_mesh.surface_set_material(0, flame_mat)
	flame_mesh.custom_aabb = AABB(Vector3(-1, 0, -1), Vector3(2, 3, 2))
