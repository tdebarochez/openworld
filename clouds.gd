extends MeshInstance3D
## Cumulus layer. The camera's far plane is only 250 m, so the clouds live on a virtual plane
## HEIGHT m up: a sphere just inside the far plane follows the camera, and each of its pixels casts
## the view ray onto that plane and reads a tiling noise texture there (world coordinates, so the
## clouds drift with the wind and the player walks under them). Unshaded and fog-free; drawn before
## every other transparent object, over the sky (hides the stars) and the fully fogged distant terrain.
## Colours come from what daynight.gd set for the hour (light, horizon haze, sky top), so no light
## logic is repeated here; the season sets the coverage.

const HEIGHT := 1200.0  # m, cloud base
const TILE := 5000.0  # m covered by one repeat of the noise texture
const WIND := Vector2(9.0, 4.0)  # m/s
const COVER := [0.3, 0.6, 0.85, 0.45]  # sky fraction-ish, by seasons.Season
const SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 lit : source_color;  // thin edges, lit by the sun / moon and the sky
uniform vec3 shade : source_color;  // thick cores, seen from below
uniform vec3 haze : source_color;  // sky horizon colour: clouds melt into it far away
uniform float cover;
uniform float height;
uniform float tile;
uniform vec2 drift;  // uv, wrapped to [0, 1)
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 dir = normalize(world_pos - CAMERA_POSITION_WORLD);
	float up = max(dir.y, 0.01);  // no branch: keeps the texture derivatives valid
	vec2 uv = (CAMERA_POSITION_WORLD.xz + dir.xz * (height - CAMERA_POSITION_WORLD.y) / up) / tile;
	float n = texture(noise_tex, uv + drift).r * 0.8 + texture(noise_tex, uv * 3.0 + drift * 4.0 + 0.37).r * 0.2;
	float edge = mix(0.72, 0.38, cover);
	float thick = smoothstep(edge, edge + 0.3, n);
	ALBEDO = mix(mix(lit, shade, thick), haze, 1.0 - smoothstep(0.02, 0.3, dir.y));
	ALPHA = smoothstep(edge, edge + 0.06, n) * smoothstep(0.0, 0.1, dir.y);
}
"""

var world  # world.gd
var cover := -1.0  # eases towards COVER[season]
var drift := Vector2.ZERO
var lit: Color
var mat := ShaderMaterial.new()


func _ready() -> void:
	if world == null:
		world = get_parent()
	var noise := FastNoiseLite.new()
	noise.seed = 99
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012  # ~3 cloud groups across a tile
	noise.fractal_octaves = 3
	var img := noise.get_seamless_image(256, 256)
	img.generate_mipmaps()
	mat.shader = Shader.new()
	mat.shader.code = SHADER
	mat.render_priority = -100  # before snow, petals, water
	mat.set_shader_parameter("noise_tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("height", HEIGHT)
	mat.set_shader_parameter("tile", TILE)
	var sphere := SphereMesh.new()
	sphere.radius = world.player.camera.far * 0.9
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	mesh = sphere
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_process(0.0)


func _process(delta: float) -> void:
	global_position = world.player.camera.global_position
	var r: float = world.player.camera.far * 0.9  # the view distance (P) moves the far plane
	if mesh.radius != r:
		mesh.radius = r
		mesh.height = r * 2.0
	drift = (drift + WIND * delta / TILE).posmod(1.0)
	var target: float = COVER[world.seasons.season]
	cover = target if cover < 0.0 else lerpf(cover, target, minf(delta * 0.3, 1.0))
	var sun: DirectionalLight3D = world.seasons.sun
	var sky: ProceduralSkyMaterial = world.seasons.sky
	var light := sun.light_color * sun.light_energy
	var haze := sky.sky_horizon_color
	var shade := sky.sky_top_color.lerp(haze, 0.6) * (1.0 - 0.35 * cover) + light * 0.15
	lit = (haze * 0.85 + light * 0.45).lerp(shade, cover * 0.5)  # overcast: flatter, greyer
	mat.set_shader_parameter("lit", lit)
	mat.set_shader_parameter("shade", shade)
	mat.set_shader_parameter("haze", haze)
	mat.set_shader_parameter("cover", cover)
	mat.set_shader_parameter("drift", drift)
