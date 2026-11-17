extends Node
## Seasons, switched with keys 1-4 (physical keys, so it works on AZERTY too).
## Everything is recoloured in place, nothing is rebuilt: terrain shader uniforms, the shared
## leaf/water materials, per-tree instance colours of loaded zones, and sun/sky/fog.
## Zones attached later pick up the current season through leaf_color().

enum Season { SUMMER, AUTUMN, WINTER, SPRING }
const NAMES := ["Été", "Automne", "Hiver", "Printemps"]

# Ground colours (sRGB) per season: sand, rock, peak, grass, road. Summer = world._ground_color and
# world.ROAD_COLOR, which the terrain shader uses as keys to recognise each category in the mesh.
const GROUND := [
	[Color(0.76, 0.7, 0.5), Color(0.45, 0.42, 0.4), Color(0.92, 0.92, 0.95), Color(0.3, 0.55, 0.2), Color(0.55, 0.45, 0.32)],
	[Color(0.76, 0.7, 0.5), Color(0.45, 0.42, 0.4), Color(0.92, 0.92, 0.95), Color(0.56, 0.5, 0.27), Color(0.5, 0.4, 0.28)],
	[Color(0.84, 0.85, 0.89), Color(0.5, 0.5, 0.53), Color(0.97, 0.98, 1.0), Color(0.9, 0.92, 0.96), Color(0.76, 0.75, 0.76)],
	[Color(0.76, 0.7, 0.5), Color(0.45, 0.42, 0.4), Color(0.92, 0.92, 0.95), Color(0.38, 0.68, 0.24), Color(0.55, 0.45, 0.32)],
]
const AUTUMN_LEAVES := [Color(0.9, 0.7, 0.12), Color(0.9, 0.45, 0.08), Color(0.75, 0.16, 0.06),
	Color(0.5, 0.3, 0.12), Color(0.85, 0.55, 0.1)]
const DRY_LEAVES := Color(0.45, 0.3, 0.15)  # the odd oak keeps its dead leaves in winter
const FRESH_LEAVES := Color(0.5, 0.8, 0.28)
const BLOSSOM := [Color(0.97, 0.78, 0.85), Color(0.97, 0.95, 0.92)]
# Sun colour/energy, haze (sky horizon + fog colour) target and mix, fog start relative to summer,
# shadow opacity relative to summer (winter's overcast light: softer shadows, incl. the snowflakes').
const LIGHT := [
	{"sun": Color.WHITE, "energy": 1.0, "haze": Color.WHITE, "mix": 0.0, "fog": 1.0, "shadow": 1.0},
	{"sun": Color(1.0, 0.85, 0.68), "energy": 0.9, "haze": Color(0.86, 0.76, 0.64), "mix": 0.45, "fog": 0.7, "shadow": 1.0},
	{"sun": Color(0.8, 0.88, 1.0), "energy": 0.65, "haze": Color(0.82, 0.86, 0.92), "mix": 0.7, "fog": 0.5, "shadow": 0.45},
	{"sun": Color(1.0, 0.98, 0.9), "energy": 1.05, "haze": Color(0.78, 0.88, 0.96), "mix": 0.2, "fog": 1.1, "shadow": 1.0},
]
const PETALS := [Color(0.97, 0.62, 0.76), Color(0.95, 0.5, 0.68), Color(0.98, 0.8, 0.88)]  # pink reads on the sky
const ICE := Color(0.62, 0.75, 0.86, 0.95)

const TERRAIN_SHADER := """
shader_type spatial;
uniform vec3 key[5];  // summer ground colours as stored in the mesh (sRGB)
uniform vec3 to[5];   // this season's colours (sRGB)
varying vec3 col;
void vertex() {
	int k = 0;
	for (int i = 1; i < 5; i++) {
		if (distance(COLOR.rgb, key[i]) < distance(COLOR.rgb, key[k])) k = i;
	}
	col = to[k];
	if (!OUTPUT_IS_SRGB) {  // same conversion as StandardMaterial3D's vertex_color_is_srgb
		col = mix(pow((col + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), col * (1.0 / 12.92), lessThan(col, vec3(0.04045)));
	}
}
void fragment() {
	ALBEDO = col;
}
"""
# Winter conifers: needles darkened by the instance colour, white on upward-facing faces.
const SNOWY_LEAVES_SHADER := """
shader_type spatial;
render_mode cull_disabled;
uniform vec3 leaf : source_color;
varying float up;
void vertex() {
	up = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
}
void fragment() {
	ALBEDO = mix(leaf * COLOR.rgb, vec3(0.9, 0.93, 0.97), smoothstep(0.3, 0.7, up));
	ROUGHNESS = 0.9;
}
"""

var world  # world.gd, set before any zone is attached
var season := Season.SUMMER
var terrain_mat := ShaderMaterial.new()
var leaf_mats: Array[StandardMaterial3D] = []  # per tree model, the tintable leaves material
var leaf_albedo: Array[Color] = []  # its summer colour
var snowy_mats: Array[ShaderMaterial] = []  # per tree model, winter leaves (used for conifers)
var roof_mats: Array[Material] = []  # per house kind, the roof (surface 1, tools/make_houses.py)
var snowy_roofs: Array[ShaderMaterial] = []  # same snowy shader: white on the slopes, roof colour below
var env: Environment
var sky: ProceduralSkyMaterial
var sun: DirectionalLight3D
var base := {}  # summer light values
const SEASON_KEYS := ["summer", "autumn", "winter", "spring"]  # as in assets/flowers/flowers.json
var flower_mats := []  # per flower kind: its original material per surface
var hidden_mat := StandardMaterial3D.new()  # alpha-scissored away, shadows included
var light := {}  # this season's noon light (keys of base); daynight.gd applies it for the hour
var snow: CPUParticles3D  # made in setup(), carried by the player
var leaves: CPUParticles3D  # autumn: dead leaves drifting down
var petals: CPUParticles3D  # spring: blossom petals floating
# The Compatibility renderer (web) shades in sRGB, so instance colours must not be linearised there.
var srgb_out := RenderingServer.get_current_rendering_method() == "gl_compatibility"


func _init() -> void:
	terrain_mat.shader = Shader.new()
	terrain_mat.shader.code = TERRAIN_SHADER
	var keys := PackedVector3Array()
	for c: Color in GROUND[Season.SUMMER]:
		keys.append(Vector3(c.r, c.g, c.b))
	terrain_mat.set_shader_parameter("key", keys)
	_set_ground()


## After world._ready made the environment, sun and player.
func setup() -> void:
	env = (world.find_children("", "WorldEnvironment", false, false)[0] as WorldEnvironment).environment
	sky = env.sky.sky_material
	sun = world.find_children("", "DirectionalLight3D", false, false)[0]
	base = {"sun": sun.light_color, "energy": sun.light_energy, "top": sky.sky_top_color,
		"haze": sky.sky_horizon_color, "fog": env.fog_depth_begin, "ambient": env.ambient_light_color,
		"water": world.water_mat.albedo_color, "water_rough": world.water_mat.roughness,
		"shadow": sun.shadow_opacity}
	light = base
	var shader := Shader.new()
	shader.code = SNOWY_LEAVES_SHADER
	for model in world.species.size():
		var mat := world.species[model].surface_get_material(1) as StandardMaterial3D
		leaf_mats.append(mat)
		leaf_albedo.append(mat.albedo_color)
		var snowy := ShaderMaterial.new()
		snowy.shader = shader
		snowy.set_shader_parameter("leaf", mat.albedo_color)
		snowy_mats.append(snowy)
	for m: Mesh in world.house_meshes:
		var roof := m.surface_get_material(1) as StandardMaterial3D
		roof_mats.append(roof)
		var snowy := ShaderMaterial.new()
		snowy.shader = shader
		snowy.set_shader_parameter("leaf", roof.albedo_color)
		snowy_roofs.append(snowy)
	hidden_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	hidden_mat.albedo_color = Color(1, 1, 1, 0)
	for f in world.flowers:
		var mats := []
		for i in f.mesh.get_surface_count():
			mats.append(f.mesh.surface_get_material(i))
		flower_mats.append(mats)
	_setup_snow()
	leaves = _drifting(AUTUMN_LEAVES, Vector2(0.24, 0.15), 320, 9.0, Vector3(0.5, -0.7, 0.25))
	petals = _drifting(PETALS, Vector2(0.11, 0.09), 400, 10.0, Vector3(0.35, -0.3, 0.15))
	for p in [snow, leaves, petals]:
		world.player.add_child(p)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode >= KEY_1 and e.physical_keycode <= KEY_4:
		set_season((e.physical_keycode - KEY_1) as Season)


func set_season(s: Season) -> void:
	season = s
	_set_ground()
	var winter := s == Season.WINTER
	world.water_mat.albedo_color = ICE if winter else base.water
	world.water_mat.roughness = 0.4 if winter else base.water_rough
	for k in world.house_meshes.size():  # snow on the roofs (shared meshes: every zone at once)
		world.house_meshes[k].surface_set_material(1, snowy_roofs[k] if winter else roof_mats[k])
	for model in world.species.size():
		if model / world.TREE_VARIANTS == world.TreeKind.CONIFER:
			world.species[model].surface_set_material(1, snowy_mats[model] if winter else leaf_mats[model])
		else:  # deciduous: instance colour carries the whole colour (and alpha = leafless in winter)
			leaf_mats[model].albedo_color = leaf_albedo[model] if s == Season.SUMMER else Color.WHITE
			leaf_mats[model].transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR if winter \
				else BaseMaterial3D.TRANSPARENCY_DISABLED
	for zone: Node3D in world.zones.values():
		for mmi in zone.get_children():
			if mmi.has_meta("trees"):
				_recolour(mmi.multimesh, mmi.get_meta("trees"), zone.position)
	var l: Dictionary = LIGHT[s]
	light = {"sun": base.sun * l.sun, "energy": base.energy * l.energy, "haze": base.haze.lerp(l.haze, l.mix),
		"top": base.top.lerp(l.haze, l.mix * 0.5), "fog": base.fog * l.fog,
		"ambient": base.ambient * l.sun}  # ambient: only used by the Compatibility renderer
	world.daynight.apply()  # final sun/sky/fog = this season's light × time of day
	sun.shadow_opacity = base.shadow * l.shadow
	_set_flowers()
	for pair in [[snow, Season.WINTER], [leaves, Season.AUTUMN], [petals, Season.SPRING]]:
		pair[0].emitting = s == pair[1]
		pair[0].visible = s == pair[1]
	world._update_hud()


## Instance colour for a tree's leaves (multiplied by its leaves material). Deterministic from position.
func leaf_color(kind: int, p: Vector3) -> Color:
	var tint: Color = world.leaf_tint(p)
	if season == Season.SUMMER:
		return tint
	if kind == world.TreeKind.CONIFER:
		return tint.darkened(0.3) if season == Season.WINTER else tint
	var pick := hash(Vector2i(roundi(p.x * 10.0), roundi(p.z * 10.0))) >> 16  # bits leaf_tint doesn't use
	var c: Color
	match season:
		Season.AUTUMN:
			c = AUTUMN_LEAVES[pick % AUTUMN_LEAVES.size()]
		Season.WINTER:
			if kind != world.TreeKind.OAK or pick % 5 != 0:
				return Color(1, 1, 1, 0)  # bare: alpha-scissored away
			c = DRY_LEAVES
		Season.SPRING:
			c = BLOSSOM[pick % 2] if pick % 4 == 0 else FRESH_LEAVES
	if not srgb_out:
		c = c.srgb_to_linear()
	return Color(c.r * tint.g, c.g * tint.g, c.b * tint.g)  # tint.g = per-tree brightness


## Rewrites a tree MultiMesh in one buffer upload (3x4 row-major transform + colour per instance),
## from the zone's placements rather than reading the GPU buffer back.
func _recolour(mm: MultiMesh, trees: Array, origin: Vector3) -> void:
	var kind: int = world.species.find(mm.mesh) / world.TREE_VARIANTS
	var buf := PackedFloat32Array()
	for t: Transform3D in trees:
		var b := t.basis
		var c := leaf_color(kind, origin + t.origin)
		buf.append_array(PackedFloat32Array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y,
			b.x.z, b.y.z, b.z.z, t.origin.z, c.r, c.g, c.b, c.a]))
	mm.buffer = buf


## In bloom: whole plant. Out of season: foliage only (surface 0). Winter: under the snow, unless
## it blooms in winter. Swaps materials on the shared meshes, so every zone follows at once.
func _set_flowers() -> void:
	for k in world.flowers.size():
		var f: Dictionary = world.flowers[k]
		var blooming: bool = SEASON_KEYS[season] in f.bloom
		var buried := season == Season.WINTER and not blooming
		for i in f.mesh.get_surface_count():
			var show: bool = blooming or (i == 0 and not buried)
			f.mesh.surface_set_material(i, flower_mats[k][i] if show else hidden_mat)


func is_blooming(kind: int) -> bool:
	return SEASON_KEYS[season] in world.flowers[kind].bloom


func _set_ground() -> void:
	var to := PackedVector3Array()
	for c: Color in GROUND[season]:
		to.append(Vector3(c.r, c.g, c.b))
	terrain_mat.set_shader_parameter("to", to)


## Snowfall around the player (CPU particles: the web build has no GPU particles).
func _setup_snow() -> void:
	snow = CPUParticles3D.new()
	snow.amount = 2000
	snow.lifetime = 8.0
	snow.preprocess = 4.0  # sky already half full on the switch; a full 8 s costs ~60 ms
	snow.local_coords = false  # flakes stay put in the world while the player moves
	snow.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	snow.emission_box_extents = Vector3(30, 1, 30)
	snow.position.y = 14.0
	snow.direction = Vector3.DOWN
	snow.spread = 20.0
	snow.gravity = Vector3(0, -0.3, 0)
	snow.initial_velocity_min = 1.2
	snow.initial_velocity_max = 2.2
	var flake := SphereMesh.new()  # tiny low-poly ball: round up close, no billboard needed
	flake.radius = 0.05
	flake.height = 0.1
	flake.radial_segments = 6
	flake.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flake.material = mat
	snow.mesh = flake
	snow.emitting = false
	snow.visible = false


## Small flat quads (leaves, petals) drifting down and twirling around the player, each with a
## random colour from `colours`. Wind = the sideways part of `gravity`. No shadows (just specks).
func _drifting(colours: Array, size: Vector2, amount: int, lifetime: float, gravity: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = lifetime * 0.5  # already drifting when the season switches
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(14, 2.5, 14)  # close to the camera, where specks read as leaves
	p.position.y = 6.0
	p.direction = Vector3.DOWN
	p.spread = 60.0
	p.gravity = gravity
	p.initial_velocity_min = 0.2
	p.initial_velocity_max = 0.8
	p.particle_flag_rotate_y = true  # spin around the vertical…
	p.angle_min = 0.0
	p.angle_max = 360.0
	p.angular_velocity_min = -220.0
	p.angular_velocity_max = 220.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.4
	var ramp := Gradient.new()  # colour_initial_ramp picks a random point per particle
	ramp.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	ramp.offsets = PackedFloat32Array(range(colours.size()).map(func(i): return float(i) / colours.size()))
	ramp.colors = PackedColorArray(colours)
	p.color_initial_ramp = ramp
	var quad := QuadMesh.new()
	quad.size = size
	quad.center_offset = Vector3(size.x * 0.4, 0, 0)  # off-centre, so the spin reads as a flutter
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = mat
	# …and tilt the quad so it shows its face, then its edge, as it spins.
	var mesh := ArrayMesh.new()
	var arrays := quad.get_mesh_arrays()
	var tilt := Basis(Vector3.RIGHT, deg_to_rad(55.0))
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i in verts.size():
		verts[i] = tilt * verts[i]
		normals[i] = tilt * normals[i]
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, mat)
	p.mesh = mesh
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.emitting = false
	p.visible = false
	return p
