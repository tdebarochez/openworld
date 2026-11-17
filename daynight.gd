extends Node
## Day/night cycle. The time of day (hours, 0-24) runs on its own and is scrubbed with +/-.
## Combines with seasons.gd: `seasons.light` holds the season's noon light (keys sun, energy, top,
## haze, fog, ambient) and apply() turns it into the final sun/sky/fog/ambient for the current hour.
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

var world  # world.gd
var time := START
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


func set_time(h: float) -> void:
	time = fposmod(h, 24.0)
	if floori(time * 60.0) != _applied:  # ~once per real second when not scrubbing
		apply()


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
	_applied = floori(time * 60.0)
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
	var haze: Color = s.haze * NIGHT_HAZE.lerp(Color.WHITE, day).lerp(DUSK_HAZE, warm)
	sky.sky_horizon_color = haze
	sky.ground_horizon_color = haze
	sky.ground_bottom_color = haze
	sky.sky_top_color = s.top * NIGHT_TOP.lerp(Color.WHITE, day)
	sky.sky_cover_modulate = Color(1, 1, 1, 1.0 - smoothstep(-0.25, -0.05, dir.y))  # stars once the sun is down
	env.fog_light_color = haze
	env.fog_depth_begin = s.fog
	env.ambient_light_color = s.ambient * NIGHT_AMBIENT.lerp(Color.WHITE, day)
	world._update_hud()


## Star field for the sky cover (equirectangular), faded in at night.
func _stars() -> ImageTexture:
	var img := Image.create(2048, 1024, false, Image.FORMAT_L8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 2500:  # uniform over the upper hemisphere (row 0 = zenith)
		var row := int(acos(rng.randf()) / PI * 1024.0)
		img.set_pixel(rng.randi() % 2048, row, Color.WHITE * rng.randf_range(0.3, 1.0))
	return ImageTexture.create_from_image(img)
