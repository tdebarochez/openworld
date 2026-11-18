extends MeshInstance3D
## Sky clouds, three layers of virtual planes (weather.HEIGHTS: high 9 km, middle 4 km, low 1.2 km). The
## camera's far plane is only 250 m-2 km, so a sphere just inside it follows the camera, and each of its
## pixels casts the view ray onto every plane and reads two tiling noise textures there (smooth fractal
## noise, cellular puffs) in wind-aligned world coordinates: the clouds drift with the wind, the player
## walks under them, and the high ones look small and slow. Each genus is a recipe on its layer's plane,
## weighted by weather.gd's amounts (blended towards the upwind horizon with the coming weather). The
## cumulonimbus tower is a billboard computed in the shader (a vertical plane facing the camera through
## the storm), sorted per pixel against the middle and low planes; lightning bolts the same way.
## Unshaded and fog-free; drawn before every other transparent object, over the sky (hides the stars)
## and the fully fogged distant terrain. Colours come from what daynight.gd set for the hour (light,
## horizon haze, sky top, already dimmed by overcast and lit by flashes), so no light logic is repeated.

const WRAP := 240000.0  # m: drifts wrap here, a whole number of repeats of every noise scale below
# m per game hour by layer (winds strengthen with height): the drift follows the game clock like the sun,
# so +/- runs it both ways. A game hour lasts 50 real s: 30, 18 and 10 m/s at normal speed.
const SPEED := Vector3(1500.0, 900.0, 500.0)
const SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled, depth_draw_never, shadows_disabled;
uniform sampler2D fbm_tex : filter_linear_mipmap, repeat_enable;  // smooth fractal noise, ~3 blobs per repeat
uniform sampler2D cell_tex : filter_linear_mipmap, repeat_enable;  // distance to the nearest of 12x12 puff centres
uniform vec3 lit : source_color;  // thin edges, lit by the sun / moon and the sky
uniform vec3 shade : source_color;  // thick cores, seen from below
uniform vec3 haze : source_color;  // sky horizon colour: clouds melt into it far away
uniform vec3 light : source_color;  // sun / moon colour x energy
uniform vec3 sun_dir;  // towards whichever of them lights the scene
uniform vec3 heights;  // m: high, middle, low plane
uniform vec3 drift;  // m each layer has moved downwind (wrapped)
uniform vec2 wind;  // unit, downwind
uniform vec3 hi_now;  // amounts: cirrus, cirrocumulus, cirrostratus
uniform vec3 hi_ahead;  // same, coming weather (upwind)
uniform vec3 mid_now;  // altocumulus, altostratus, nimbostratus
uniform vec3 mid_ahead;
uniform vec3 low_now;  // stratocumulus, stratus, cumulus
uniform vec3 low_ahead;
uniform vec4 storm;  // cumulonimbus: world xz, amount, base radius
uniform vec4 bolt;  // lightning: world xz, brightness, shape seed
varying vec3 world_pos;

float fbm(vec2 p) { return texture(fbm_tex, p).r; }
float cell(vec2 p) { return texture(cell_tex, p).r; }

// Premultiplied colour + alpha, `a` of `col` laid over `acc`.
vec4 over(vec4 acc, vec3 col, float a) { return vec4(col * a, a) + acc * (1.0 - a); }

// Ray onto a vertical plane facing the camera through world xz `at`: (across offset, altitude, distance).
vec3 billboard(vec3 cam, vec3 dir, vec2 at) {
	vec2 to = at - cam.xz;
	vec2 n = to / max(length(to), 1.0);
	float t = dot(to, n) / max(dot(dir.xz, n), 1e-3);
	vec3 q = cam + dir * t;
	return vec3(dot(q.xz - at, vec2(-n.y, n.x)), q.y, t);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 dir = normalize(world_pos - cam);
	float up = max(dir.y, 0.01);  // no branch: keeps the texture derivatives valid
	float fade = smoothstep(0.0, 0.1, dir.y);  // the planes end at the horizon…
	float hz = 1.0 - smoothstep(0.02, 0.3, dir.y);  // …melting into the haze before
	vec2 perp = vec2(-wind.y, wind.x);
	float sun_cos = dot(dir, sun_dir);
	vec3 ahead_k = vec3(0.0);  // per layer: how far upwind the hit is (0 overhead → 1 at 30 km)
	vec2 hit[3];
	vec2 q[3];  // wind-aligned (along, across) after the drift: whole repeats when a drift wraps
	for (int i = 0; i < 3; i++) {
		vec2 rel = dir.xz * (heights[i] - cam.y) / up;
		hit[i] = cam.xz + rel;
		q[i] = vec2(dot(hit[i], wind) - drift[i], dot(hit[i], perp));
		ahead_k[i] = smoothstep(0.0, 30000.0, -dot(rel, wind));
	}

	// High: cirrus streaks along the wind, bent into hooks; cirrocumulus grains in ripples; cirrostratus veil.
	vec4 H = vec4(0.0);
	vec3 a = mix(hi_now, hi_ahead, ahead_k.x);
	if (hi_now.x + hi_ahead.x > 0.0) {
		float warp = fbm(q[0] / 60000.0) - 0.5;
		float s = fbm(vec2(q[0].x / 30000.0, (q[0].y + warp * 4000.0) / 4000.0));
		float fibre = fbm(vec2(q[0].x / 8000.0, (q[0].y + warp * 4000.0) / 400.0) + 0.5);
		float patch = smoothstep(0.0, 0.2, fbm(q[0] / 48000.0 + 0.3) - mix(0.75, 0.3, a.x));
		H = over(H, lit * 1.05, smoothstep(0.5, 0.8, s) * smoothstep(0.25, 0.75, fibre) * patch * 0.75 * min(a.x * 3.0, 1.0));
	}
	if (hi_now.y + hi_ahead.y > 0.0) {
		float rip = sin((q[0].x + fbm(q[0] / 20000.0) * 8000.0) * TAU / 800.0) * 0.5 + 0.5;
		float patch = smoothstep(0.0, 0.25, fbm(q[0] / 30000.0 + 0.6) - mix(0.75, 0.25, a.y));
		float grain = 1.0 - smoothstep(0.25, 0.55, cell(q[0] / 2400.0) + 0.35 * (1.0 - rip));
		H = over(H, lit, grain * patch * 0.85 * min(a.y * 3.0, 1.0));
	}
	if (hi_now.z + hi_ahead.z > 0.0) {
		float f = fbm(vec2(q[0].x / 40000.0, q[0].y / 4000.0)) * 0.6 + fbm(q[0] / 15000.0 + 0.2) * 0.4;
		float off = (acos(clamp(sun_cos, -1.0, 1.0)) - 0.384) / 0.02;
		float ring = exp(-off * off);  // 22° halo
		H = over(H, lit * 1.05 + light * ring * 0.5, a.z * (0.12 + 0.25 * f + 0.1 * ring));
	}
	H = vec4(mix(H.rgb, haze * H.a, hz), H.a) * fade;

	// Middle: altocumulus puffs in rows; altostratus grey-blue sheet (sun as through frosted glass);
	// nimbostratus dark featureless sheet.
	vec4 M = vec4(0.0);
	a = mix(mid_now, mid_ahead, ahead_k.y);
	if (mid_now.x + mid_ahead.x > 0.0) {
		float rows = sin((q[1].x + fbm(q[1] / 30000.0) * 10000.0) * TAU / 2000.0) * 0.5 + 0.5;
		float patch = smoothstep(0.0, 0.25, fbm(q[1] / 40000.0 + 0.1) - mix(0.7, 0.2, a.x));
		float puff = (1.0 - cell(q[1] / 6000.0)) - 0.3 * (1.0 - rows) + 0.6 * (fbm(q[1] / 1500.0) - 0.5) - (1.0 - patch);
		M = over(M, mix(lit, shade * 1.05, smoothstep(0.4, 0.75, puff) * 0.65), smoothstep(0.3, 0.5, puff) * min(a.x * 3.0, 1.0));
	}
	if (mid_now.y + mid_ahead.y > 0.0) {
		float f = fbm(q[1] / 40000.0 + 0.7) * 0.6 + fbm(vec2(q[1].x / 20000.0, q[1].y / 5000.0)) * 0.4;
		vec3 col = mix(shade, lit, 0.45 + 0.3 * f) * vec3(0.95, 0.97, 1.04) + light * pow(max(sun_cos, 0.0), 200.0) * 1.5;
		M = over(M, col, a.y * (0.8 + 0.15 * f));
	}
	if (mid_now.z + mid_ahead.z > 0.0) {
		float f = fbm(q[1] / 30000.0 + 0.4) * 0.7 + fbm(q[1] / 8000.0) * 0.3;
		M = over(M, shade * (0.5 + 0.2 * f), smoothstep(0.0, 0.6, a.z));
	}
	M = vec4(mix(M.rgb, haze * M.a, hz), M.a) * fade;

	// Low: stratus hazy grey layer; stratocumulus lumpy rolls with gaps; cumulus puffs; storm base.
	vec4 L = vec4(0.0);
	a = mix(low_now, low_ahead, ahead_k.z);
	if (low_now.y + low_ahead.y > 0.0) {
		float f = fbm(q[2] / 30000.0 + 0.9) * 0.7 + fbm(vec2(q[2].x / 12000.0, q[2].y / 4000.0)) * 0.3;
		L = over(L, mix(shade, haze, 0.35) * (0.85 + 0.15 * f), a.y * (0.85 + 0.15 * f));
	}
	if (low_now.x + low_ahead.x > 0.0) {
		float n = fbm(q[2] / 12000.0 + 0.15);
		float c = 1.0 - cell(q[2] / 8000.0 + (n - 0.5) * 0.12);  // warped: lumps, not discs
		float edge = mix(0.7, 0.15, a.x);
		vec3 col = mix(lit * 0.95, shade * 0.75, smoothstep(0.3, 0.8, n * 0.75 + c * 0.25));
		L = over(L, col, smoothstep(edge, edge + 0.12, (c + n) * 0.5) * min(a.x * 3.0, 1.0));
	}
	if (low_now.z + low_ahead.z > 0.0) {
		float n = fbm(q[2] / 5000.0) * 0.8 + fbm(q[2] / 5000.0 * 3.0 + 0.37) * 0.2;
		float edge = mix(0.72, 0.38, a.z);
		L = over(L, mix(lit, shade, smoothstep(edge, edge + 0.3, n)), smoothstep(edge, edge + 0.06, n) * min(a.z * 4.0, 1.0));
	}
	if (storm.z > 0.0) {
		float r = distance(hit[2], storm.xy) + (fbm(q[2] / 12000.0 + 0.5) - 0.5) * 3000.0;
		L = over(L, shade * (0.3 + 0.15 * cell(q[2] / 12000.0)), smoothstep(storm.w, storm.w * 0.5, r) * smoothstep(0.0, 0.2, storm.z));
	}
	L = vec4(mix(L.rgb, haze * L.a, hz), L.a) * fade;

	// Cumulonimbus tower: a column swelling upwards, then the anvil spreading downwind under a flat top;
	// lumpy cauliflower edges, sunny side and top bright, base dark; rain shaft under it.
	vec4 T = vec4(0.0);
	float t_tower = 1e9;
	if (storm.z > 0.05) {
		vec3 b = billboard(cam, dir, storm.xy);
		t_tower = b.z;
		vec2 to = normalize(storm.xy - cam.xz + 1e-3);
		vec2 across = vec2(-to.y, to.x);
		float top = 1200.0 + 10500.0 * smoothstep(0.05, 0.45, storm.z);
		float h = (b.y - 1200.0) / (top - 1200.0);
		float anvil = smoothstep(0.75, 0.95, h);
		float u = b.x - dot(wind, across) * anvil * 8000.0;
		float w = 3500.0 + 2000.0 * smoothstep(0.0, 0.75, h) + anvil * 12000.0;
		float lumps = fbm(b.xy / 12000.0 + 0.2) - 0.5;
		float lobe = cell(b.xy / 16000.0 + lumps * 0.1);  // ~1.3 km cauliflower lobes, warped
		float edge = w * (1.0 + 0.4 * lumps) - abs(u) - lobe * 1500.0 * (1.0 - anvil);
		float d = smoothstep(0.0, 300.0, edge) * smoothstep(0.0, 0.02, h) * (1.0 - smoothstep(0.97, 1.0, h + lumps * 0.06));
		vec2 sun_h = normalize(sun_dir.xz + 1e-4);
		float side = 0.5 + 0.5 * clamp(u / w, -1.0, 1.0) * dot(sun_h, across) - 0.25 * dot(sun_h, to);
		float bright = clamp(0.65 * smoothstep(0.0, 0.85, h) + 0.3 * side + 0.3 * (1.0 - lobe) - 0.15, 0.0, 1.0);
		vec3 col = mix(shade * 0.3, lit * 1.1 + light * 0.15, bright);
		float shaft = 0.45 * smoothstep(0.0, 800.0, 2600.0 - abs(b.x)) * step(0.0, b.y) * (1.0 - step(0.0, h))
			* (0.6 + 0.4 * fbm(vec2(b.x / 3000.0, b.y / 30000.0)));
		col = mix(col, shade * 0.6, shaft * (1.0 - d));
		d = max(d, shaft);
		col = mix(col, haze, clamp(t_tower / 60000.0, 0.0, 0.6));
		d *= smoothstep(storm.w * 0.4, storm.w * 0.8, distance(storm.xy, cam.xz)) * smoothstep(0.0, 0.05, dot(dir.xz, to))
			* smoothstep(-0.01, 0.01, dir.y);
		T = vec4(col * d, d);
	}

	// Lightning bolt: a jagged line from the cloud base to the ground.
	vec4 B = vec4(0.0);
	if (bolt.z > 0.01) {
		vec3 b = billboard(cam, dir, bolt.xy);
		float s = bolt.w;
		float x = 150.0 * sin(b.y * 0.0031 + s) + 70.0 * sin(b.y * 0.0113 + s * 2.3)
			+ 30.0 * sin(b.y * 0.037 + s * 5.1) + 12.0 * sin(b.y * 0.09 + s * 1.7);
		float width = max(4.0, b.z * 0.0015);
		float i = (exp(-abs(b.x - x) / width) + 0.3 * exp(-abs(b.x - x) / (width * 10.0)))
			* step(-50.0, b.y) * step(b.y, 1200.0) * step(0.0, dot(dir.xz, bolt.xy - cam.xz)) * bolt.z;
		B = vec4(vec3(0.9, 0.9, 1.0) * i, min(i, 1.0));
	}

	// Back to front; the tower goes behind or in front of the middle and low planes along this ray.
	float t_mid = (heights.y - cam.y) / up;
	float t_low = (heights.z - cam.y) / up;
	float behind_mid = step(t_mid, t_tower);
	float behind_low = step(t_low, t_tower);
	vec4 acc = H;
	acc = T * behind_mid + acc * (1.0 - T.a * behind_mid);
	acc = M + acc * (1.0 - M.a);
	acc = T * (behind_low - behind_mid) + acc * (1.0 - T.a * (behind_low - behind_mid));
	acc = L + acc * (1.0 - L.a);
	acc = T * (1.0 - behind_low) + acc * (1.0 - T.a * (1.0 - behind_low));
	acc = B + acc * (1.0 - B.a);
	ALBEDO = acc.rgb / max(acc.a, 1e-4);
	ALPHA = acc.a;
}
"""

var world  # world.gd
var drift := Vector3.ZERO  # m per layer
var lit: Color
var mat := ShaderMaterial.new()


func _ready() -> void:
	if world == null:
		world = get_parent()
	var noise := FastNoiseLite.new()
	noise.seed = 99
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012  # ~3 cloud groups across a repeat
	noise.fractal_octaves = 3
	# Half floats: 8-bit texels filter in 8-bit steps, which the clouds' sharp ramps turn into bands.
	var img := noise.get_seamless_image(256, 256)
	img.convert(Image.FORMAT_RH)
	img.generate_mipmaps()
	var puffs := cells(128, 12, 7)
	puffs.generate_mipmaps()
	mat.shader = Shader.new()
	mat.shader.code = SHADER
	mat.render_priority = -100  # before snow, petals, water
	mat.set_shader_parameter("fbm_tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("cell_tex", ImageTexture.create_from_image(puffs))
	mat.set_shader_parameter("heights", Vector3(world.weather.HEIGHTS[0], world.weather.HEIGHTS[1], world.weather.HEIGHTS[2]))
	var sphere := SphereMesh.new()
	sphere.radius = world.player.camera.far * 0.9
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	mesh = sphere
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_process(0.0)


## Tiling cellular noise: distance to the nearest of n x n jittered points (wrapping), 0 at a point.
## FastNoiseLite's seamless images cross-fade their edges, which shows as seams with cells.
static func cells(size: int, n: int, seed: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var pts := PackedVector2Array()
	for i in n * n:
		pts.append(Vector2(i % n + rng.randf_range(0.1, 0.9), i / n + rng.randf_range(0.1, 0.9)))
	var data := PackedFloat32Array()
	data.resize(size * size)
	var k := float(n) / size
	for y in size:
		for x in size:
			var p := Vector2((x + 0.5) * k, (y + 0.5) * k)
			var best := 9.0
			for j in range(-1, 2):
				for i in range(-1, 2):
					var gx := int(p.x) + i
					var gy := int(p.y) + j
					var c := pts[posmod(gy, n) * n + posmod(gx, n)] + Vector2(gx - posmod(gx, n), gy - posmod(gy, n))
					best = minf(best, p.distance_squared_to(c))
			data[y * size + x] = minf(sqrt(best) / 0.75, 1.0)
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RF, data.to_byte_array())
	img.convert(Image.FORMAT_RH)
	return img


func _process(_delta: float) -> void:
	global_position = world.player.camera.global_position
	var r: float = world.player.camera.far * 0.9  # the view distance (P) moves the far plane
	if mesh.radius != r:
		mesh.radius = r
		mesh.height = r * 2.0
	var wx = world.weather
	var h: float = world.daynight.hours()  # 64-bit: wrapped before it reaches the 32-bit shader
	drift = Vector3(fposmod(h * SPEED.x, WRAP), fposmod(h * SPEED.y, WRAP), fposmod(h * SPEED.z, WRAP))
	var sun: DirectionalLight3D = world.seasons.sun
	var sky = world.seasons.sky
	var light := sun.light_color * sun.light_energy
	var haze: Color = sky.sky_horizon_color
	var shade: Color = sky.sky_top_color.lerp(haze, 0.6) * (1.0 - 0.35 * wx.overcast) + light * 0.15
	lit = (haze * 0.85 + light * 0.45).lerp(shade, wx.overcast * 0.5)  # overcast: flatter, greyer
	mat.set_shader_parameter("lit", lit)
	mat.set_shader_parameter("shade", shade)
	mat.set_shader_parameter("haze", haze)
	mat.set_shader_parameter("light", light)
	mat.set_shader_parameter("sun_dir", sun.global_basis.z)
	mat.set_shader_parameter("drift", drift)
	mat.set_shader_parameter("wind", wx.wind)
	var a: PackedFloat32Array = wx.amt
	var b: PackedFloat32Array = wx.ahead
	var G = wx.G
	mat.set_shader_parameter("hi_now", Vector3(a[G.CI], a[G.CC], a[G.CS]))
	mat.set_shader_parameter("hi_ahead", Vector3(b[G.CI], b[G.CC], b[G.CS]))
	mat.set_shader_parameter("mid_now", Vector3(a[G.AC], a[G.AS], a[G.NS]))
	mat.set_shader_parameter("mid_ahead", Vector3(b[G.AC], b[G.AS], b[G.NS]))
	mat.set_shader_parameter("low_now", Vector3(a[G.SC], a[G.ST], a[G.CU]))
	mat.set_shader_parameter("low_ahead", Vector3(b[G.SC], b[G.ST], b[G.CU]))
	mat.set_shader_parameter("storm", Vector4(wx.storm.x, wx.storm.y, a[G.CB], wx.STORM_BASE))
	mat.set_shader_parameter("bolt", Vector4(wx.bolt.x, wx.bolt.y, wx.strobe, wx.bolt_seed))
