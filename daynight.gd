extends Node
## Day/night cycle. The time of day (hours, 0-24) runs on its own and is scrubbed with +/-.
## Combines with seasons.gd: `seasons.light` holds the season's noon light (keys sun, energy, top,
## haze, fog, ambient, shadow) and apply() turns it into the final sun/sky/fog/ambient for the current
## hour and weather (weather.gd's overcast, rain and lightning flash).
## seasons.set_season() stores its values there and calls apply(); nothing else writes those.
## At night the DirectionalLight3D becomes the moon (opposite the sun). The sky's sun/moon disc
## comes from a separate sky-only light: lit by the dim scene light, it showed as a dark blob in
## front of the bright winter haze at sunset.

const NOON := 13.0  # sun due south at its highest
# Real sun path at a mid-latitude: noon elevation 90° - LATITUDE + declination (67° summer, 21° winter),
# so summer days are long and winter days short. Dusk, moon, stars and disc all follow dir.y.
const LATITUDE := deg_to_rad(46.0)
const DECLINATION := [deg_to_rad(23.4), 0.0, deg_to_rad(-23.4), 0.0]  # by seasons.Season
const START := 10.0
const DAY_SECONDS := 1200.0  # real seconds per game day (20 min)
const SCRUB_SPEED := 2.0  # game hours per real second while + or - is held
const TAP := 0.25  # game hours per press
# Multipliers of the season's colours (white = the season's noon look).
const SUN_WARM := Color(1.0, 0.55, 0.3)
const MOON := Color(0.55, 0.65, 1.0)
const MOON_ENERGY := 0.35
const DUSK_HAZE := Color(1.45, 0.8, 0.5)
const NIGHT_HAZE := Color(0.1, 0.14, 0.3)
const NIGHT_TOP := Color(0.04, 0.07, 0.2)
const NIGHT_AMBIENT := Color(0.3, 0.4, 0.75)  # Compatibility renderer only (flat ambient)
const FLASH := 0.7  # sky brightening by a close lightning strike
# Milky Way: pole of its great circle (22° up towards SE, so the band arches 68° high from SW to NE),
# core longitude along it from the SW horizon (24° up in the WSW), and glow colours/strength (sRGB).
const GALAXY_POLE := Vector3(0.656, 0.375, 0.656)
const CORE_L := 0.45
const MW_WARM := Color(1.0, 0.85, 0.66)
const MW_COOL := Color(0.72, 0.82, 1.0)
const MW_STRENGTH := 0.22
const MW_GRID := 384  # glow computed at this width, then upscaled (build time ~ MW_GRID²)

var world  # world.gd
var time := START
var day := 0
var held := {}  # physical keycode -> +1/-1 while a +/- key is down
var _applied := -1  # minute of the day last applied
var disc := DirectionalLight3D.new()  # sky-only: draws the sun/moon, lights nothing


func _ready() -> void:
	world.seasons.sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	disc.sky_mode = DirectionalLight3D.SKY_MODE_SKY_ONLY
	add_child(disc)
	world.seasons.sky.sky_cover = _stars()
	apply()


## +1 for '+' (also the unshifted '=' key on QWERTY and the keypad), -1 for '-', else 0.
static func key_dir(e: InputEventKey) -> int:
	if e.unicode == 43 or e.keycode in [KEY_PLUS, KEY_EQUAL, KEY_KP_ADD]:
		return 1
	if e.unicode == 45 or e.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]:
		return -1
	return 0


func _unhandled_input(e: InputEvent) -> void:
	if not e is InputEventKey or e.echo:
		return
	if not e.pressed:  # release events carry no unicode, so match the press by physical key
		held.erase(e.physical_keycode)
		return
	var d := key_dir(e)
	if d:
		held[e.physical_keycode] = d
		set_time(time + d * TAP)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		held.clear()  # the release would be missed


func _process(delta: float) -> void:
	var scrub := 0
	for d in held.values():
		scrub += d
	set_time(time + delta * (24.0 / DAY_SECONDS + SCRUB_SPEED * clampi(scrub, -1, 1)))


## Applied every frame: stepping the light once per game minute made every shadow jump 0.25°.
func set_time(h: float) -> void:
	day += floori(h / 24.0)  # past midnight either way
	time = fposmod(h, 24.0)
	apply()


## Game hours since day 0 at midnight: the clock the weather and the cloud drift follow.
func hours() -> float:
	return day * 24.0 + time


func clock() -> String:
	var m := floori(time * 60.0)
	return "%02d:%02d" % [m / 60, m % 60]


## Unit vector towards the sun (+X east, +Y up, +Z south) for a solar declination: rises in the east
## (north of it in summer, south in winter), due south at NOON, sets in the west.
static func sun_dir(h: float, decl := 0.0) -> Vector3:
	var a := (h - NOON) / 24.0 * TAU  # hour angle
	return Vector3(-cos(decl) * sin(a),
		sin(LATITUDE) * sin(decl) + cos(LATITUDE) * cos(decl) * cos(a),
		sin(LATITUDE) * cos(decl) * cos(a) - cos(LATITUDE) * sin(decl))


func apply() -> void:
	var s: Dictionary = world.seasons.light
	var sun: DirectionalLight3D = world.seasons.sun
	var sky: ProceduralSkyMaterial = world.seasons.sky
	var env: Environment = world.seasons.env
	var dir := sun_dir(time, DECLINATION[world.seasons.season])
	var day := smoothstep(-0.15, 0.2, dir.y)
	# Peaks at sunrise/sunset, gone by ~11° so the low winter sun (10:00 ≈ 9.5°) doesn't paint a dawn sky.
	var warm := 1.0 - smoothstep(0.0, 0.2, absf(dir.y - 0.02))
	if dir.y >= 0.0:
		sun.basis = Basis.looking_at(-dir)
		sun.light_color = s.sun * Color.WHITE.lerp(SUN_WARM, warm)
		sun.light_energy = s.energy * smoothstep(0.0, 0.1, dir.y)
	else:  # both lights are 0 at the horizon, so the swap doesn't show
		sun.basis = Basis.looking_at(dir)
		sun.light_color = s.sun * MOON
		sun.light_energy = s.energy * MOON_ENERGY * smoothstep(0.0, 0.15, -dir.y)
	disc.basis = sun.basis
	disc.light_color = sun.light_color
	disc.light_energy = (1.0 + warm) * smoothstep(0.0, 0.05, dir.y) if dir.y >= 0.0 \
		else 0.6 * smoothstep(0.0, 0.05, -dir.y)
	# Weather: overcast dims the sun and its shadows and greys the sky, rain shortens the view,
	# lightning flashes the sky and the ambient light.
	var wx = world.weather
	var dim: float = wx.overcast if wx else 0.0
	var flash: Color = Color(1, 1, 1, 0) * (wx.flash * FLASH if wx else 0.0)
	sun.light_energy *= 1.0 - 0.75 * dim
	sun.shadow_opacity = s.shadow * (1.0 - 0.85 * dim)
	var haze: Color = _grey(s.haze * NIGHT_HAZE.lerp(Color.WHITE, day).lerp(DUSK_HAZE, warm), dim) + flash
	sky.sky_horizon_color = haze
	sky.ground_horizon_color = haze
	sky.ground_bottom_color = haze
	sky.sky_top_color = _grey(s.top * NIGHT_TOP.lerp(Color.WHITE, day), dim) + flash
	# Stars once the sun is down, hidden by overcast (sheet clouds aren't quite opaque, stars are bright).
	sky.sky_cover_modulate = Color(1, 1, 1, (1.0 - smoothstep(-0.25, -0.05, dir.y)) * (1.0 - dim))
	env.fog_light_color = haze
	env.fog_depth_begin = s.fog * (1.0 - 0.6 * (wx.rain if wx else 0.0))
	env.ambient_light_color = s.ambient * NIGHT_AMBIENT.lerp(Color.WHITE, day) * (1.0 - 0.3 * dim)
	env.ambient_light_energy = world.seasons.base.ambient_energy * (1.0 + 6.0 * flash.r)
	if floori(time * 60.0) != _applied:  # the clock only shows minutes: don't relayout the HUD every frame
		_applied = floori(time * 60.0)
		world._update_hud()


## Overcast sky: towards its own grey, darker.
static func _grey(c: Color, dim: float) -> Color:
	var l := c.get_luminance()
	return c.lerp(Color(l, l, l * 1.05), dim * 0.8) * (1.0 - 0.45 * dim)


## Star field and Milky Way for the sky cover (equirectangular, row 0 = zenith), faded in at night.
func _stars() -> ImageTexture:
	var glow := _milky_way()
	glow.resize(2048, 512, Image.INTERPOLATE_BILINEAR)  # the glow is soft: a coarse grid is enough
	var img := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	img.blit_rect(glow, Rect2i(0, 0, 2048, 512), Vector2i.ZERO)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 2500:  # uniform over the upper hemisphere
		var row := int(acos(rng.randf()) / PI * 1024.0)
		img.set_pixel(rng.randi() % 2048, row, Color.WHITE * rng.randf_range(0.3, 1.0))
	var e := _galaxy_axes()
	for i in 4000:  # faint stars crowding along the band, most around the core
		var l := rng.randf() * TAU
		var core := _core(l)
		var b := rng.randfn(0.0, 0.05 + 0.07 * core)
		var d: Vector3 = (e[0] * cos(l) + e[1] * sin(l)) * cos(b) + e[2] * sin(b)
		if d.y <= 0.0 or rng.randf() > 0.35 + 0.65 * core:
			continue
		var px := Vector2i(int(fposmod(atan2(d.x, -d.z) / TAU, 1.0) * 2048.0) % 2048, int(acos(d.y) / PI * 1024.0))
		img.set_pixelv(px, img.get_pixelv(px) + Color.WHITE * rng.randf_range(0.08, 0.3))
	return ImageTexture.create_from_image(img)


## [e1, e2, pole] of the Milky Way's great circle: e1 on the horizon (south-west), e2 its top.
func _galaxy_axes() -> Array:
	var n := GALAXY_POLE.normalized()
	var e1 := n.cross(Vector3.UP).normalized()
	return [e1, e1.cross(n), n]


## 1 at the galactic core (longitude CORE_L along the band), 0 far from it.
func _core(l: float) -> float:
	return exp(-pow(angle_difference(l, CORE_L) / 0.6, 2.0))


## Milky Way glow on a coarse MW_GRID x MW_GRID/4 grid, the sky half of an equirectangular map (~1° per
## texel): a soft band around the great circle, wider, brighter and warmer at the core, split by dust
## lanes, dimmed near the horizon. Noise is sampled at the 3D direction: no seam, no zenith stretching.
func _milky_way() -> Image:
	var gw := MW_GRID
	var gh := MW_GRID / 4
	var img := Image.create(gw, gh, false, Image.FORMAT_RGB8)
	var e := _galaxy_axes()
	var e1: Vector3 = e[0]
	var e2: Vector3 = e[1]
	var n: Vector3 = e[2]
	var clumps := FastNoiseLite.new()
	clumps.seed = 3
	clumps.frequency = 2.0  # per unit of direction: ~30° clouds
	clumps.fractal_octaves = 3
	var dust := FastNoiseLite.new()
	dust.seed = 5
	dust.frequency = 6.0
	dust.fractal_octaves = 4
	var sp := PackedFloat32Array()
	var cp := PackedFloat32Array()
	for x in gw:
		sp.append(sin((x + 0.5) / gw * TAU))
		cp.append(cos((x + 0.5) / gw * TAU))
	for y in gh:
		var st := sin((y + 0.5) / (2 * gh) * PI)
		var ct := cos((y + 0.5) / (2 * gh) * PI)
		var fade := smoothstep(0.0, 0.3, ct)  # extinction near the horizon
		for x in gw:
			var d := Vector3(st * sp[x], ct, -st * cp[x])
			var b := d.dot(n)  # sine of the galactic latitude
			if absf(b) > 0.6:
				continue
			var core := _core(atan2(d.dot(e2), d.dot(e1)))
			var c := clumps.get_noise_3dv(d)
			var w := (0.1 + 0.1 * core) * (1.0 + 0.35 * c)
			var r := b / w
			var k := dust.get_noise_3dv(d)
			var rift := (b - 0.04 * c) / (0.3 * w)
			var glow := (exp(-r * r) * (0.6 + 0.4 * core) * (0.8 + 0.4 * c) + 0.15 * exp(-r * r / 3.24)) \
				* (1.0 - 0.7 * exp(-rift * rift) * smoothstep(-0.3, 0.2, k)) \
				* (1.0 - 0.4 * smoothstep(0.0, 0.5, k)) * fade  # rift along the plane, patchy dust
			img.set_pixel(x, y, MW_COOL.lerp(MW_WARM, clampf(core + 0.3 * c, 0.0, 1.0)) * (glow * MW_STRENGTH))
	return img
