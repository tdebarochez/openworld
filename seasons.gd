extends Node
## Seasons, switched with keys 1-4 (physical keys, so it works on AZERTY too).
## Everything is recoloured in place, nothing is rebuilt: terrain shader uniforms, the shared
## leaf/water materials, per-tree instance colours of loaded zones, and sun/sky/fog.
## Zones attached later pick up the current season through leaf_color().

enum Season { SUMMER, AUTUMN, WINTER, SPRING }
const NAMES := ["Été", "Automne", "Hiver", "Printemps"]

# Ground colours (sRGB) per season: sand, rock, peak, grass. Summer = world._ground_color, which
# the terrain shader uses as keys to recognise each category in the mesh's vertex colours.
const GROUND := [
	[Color(0.76, 0.7, 0.5), Color(0.45, 0.42, 0.4), Color(0.92, 0.92, 0.95), Color(0.3, 0.55, 0.2)],
	[Color(0.76, 0.7, 0.5), Color(0.45, 0.42, 0.4), Color(0.92, 0.92, 0.95), Color(0.56, 0.5, 0.27)],
	[Color(0.84, 0.85, 0.89), Color(0.5, 0.5, 0.53), Color(0.97, 0.98, 1.0), Color(0.9, 0.92, 0.96)],
	[Color(0.76, 0.7, 0.5), Color(0.45, 0.42, 0.4), Color(0.92, 0.92, 0.95), Color(0.38, 0.68, 0.24)],
]
const AUTUMN_LEAVES := [Color(0.9, 0.7, 0.12), Color(0.9, 0.45, 0.08), Color(0.75, 0.16, 0.06),
	Color(0.5, 0.3, 0.12), Color(0.85, 0.55, 0.1)]
const DRY_LEAVES := Color(0.45, 0.3, 0.15)  # the odd oak keeps its dead leaves in winter
const FRESH_LEAVES := Color(0.5, 0.8, 0.28)
const BLOSSOM := [Color(0.97, 0.78, 0.85), Color(0.97, 0.95, 0.92)]
# Sun colour/energy, haze (sky horizon + fog colour) target and mix, fog start relative to summer.
const LIGHT := [
	{"sun": Color.WHITE, "energy": 1.0, "haze": Color.WHITE, "mix": 0.0, "fog": 1.0},
	{"sun": Color(1.0, 0.85, 0.68), "energy": 0.9, "haze": Color(0.86, 0.76, 0.64), "mix": 0.45, "fog": 0.7},
	{"sun": Color(0.8, 0.88, 1.0), "energy": 0.65, "haze": Color(0.82, 0.86, 0.92), "mix": 0.7, "fog": 0.5},
	{"sun": Color(1.0, 0.98, 0.9), "energy": 1.05, "haze": Color(0.78, 0.88, 0.96), "mix": 0.2, "fog": 1.1},
]
const ICE := Color(0.62, 0.75, 0.86, 0.95)

const TERRAIN_SHADER := """
shader_type spatial;
uniform vec3 key[4];  // summer ground colours as stored in the mesh (sRGB)
uniform vec3 to[4];   // this season's colours (sRGB)
varying vec3 col;
void vertex() {
	int k = 0;
	for (int i = 1; i < 4; i++) {
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
var env: Environment
var sky: ProceduralSkyMaterial
var sun: DirectionalLight3D
var base := {}  # summer light values
var snow: CPUParticles3D  # made in setup(), carried by the player
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
		"water": world.water_mat.albedo_color, "water_rough": world.water_mat.roughness}
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
	_setup_snow()
	world.player.add_child(snow)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode >= KEY_1 and e.physical_keycode <= KEY_4:
		set_season((e.physical_keycode - KEY_1) as Season)


func set_season(s: Season) -> void:
	season = s
	_set_ground()
	var winter := s == Season.WINTER
	world.water_mat.albedo_color = ICE if winter else base.water
	world.water_mat.roughness = 0.4 if winter else base.water_rough
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
	sun.light_color = base.sun * l.sun
	sun.light_energy = base.energy * l.energy
	var haze: Color = base.haze.lerp(l.haze, l.mix)
	sky.sky_horizon_color = haze
	sky.ground_horizon_color = haze
	sky.ground_bottom_color = haze
	sky.sky_top_color = base.top.lerp(l.haze, l.mix * 0.5)
	env.fog_light_color = haze
	env.fog_depth_begin = base.fog * l.fog
	env.ambient_light_color = base.ambient * l.sun  # only used by the Compatibility renderer
	snow.emitting = winter
	snow.visible = winter
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
