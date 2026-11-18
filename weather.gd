extends Node
## Weather: how much of each cloud genus is in the sky (0-1), rain/snow and thunderstorms.
## Like the sun, the sky is a pure function of daynight's game clock (day × 24 + hour), the season and
## the seed: holding +/- runs the weather (and clouds.gd's wind drift) forwards or backwards, smoothly.
## Auto: each SLOT-hour slot runs a scenario picked from the slot number with the season's weights; its
## keys are evenly spaced and the last one blends into the next slot's first, so nothing jumps. The sky
## upwind shows the weather LEAD hours ahead (clouds.gd blends `ahead` in towards the upwind horizon),
## so fronts roll in. N / Shift+N: pins a preset (one genus each, then a thunderstorm overhead) until
## cycled back to auto, which resumes the schedule at the current hour.
## Owns the rain particles and seasons.snow's emitting (snow = precipitation in winter), lightning and
## thunder. daynight.apply() reads `overcast`, `rain` and `flash`: it stays the only writer of the light.

enum G { CI, CC, CS, AC, AS, NS, SC, ST, CU, CB }
const NAMES := ["Cirrus", "Cirrocumulus", "Cirrostratus", "Altocumulus", "Altostratus", "Nimbostratus",
	"Stratocumulus", "Stratus", "Cumulus", "Cumulonimbus"]
const HEIGHTS := [9000.0, 4000.0, 1200.0]  # m, plane of the high (5-13 km), middle (2-7) and low (0-2) layer
const SLOT := 9.0  # game hours per scenario
const FAIR_SLOTS := 1  # slots 0..1 (the first 18 game hours, the game starts at 10:00) are fair weather
const LEAD := 1.5  # game hours
const SEED := 4711
# Share of the light each genus blocks when it covers the sky (cumulonimbus: only under its base;
# fair-weather cumulus and cirrus leave the sun alone).
const DIM := [0.0, 0.05, 0.15, 0.25, 0.55, 0.85, 0.45, 0.6, 0.0, 0.0]
const STORM_FAR := 30000.0  # m: a cumulonimbus grows and comes closer as its amount rises (0 = overhead)
const STORM_BASE := 6000.0  # m, radius of its dark base: rain and close lightning under it
const LIGHTNING_MIN := 0.3  # cumulonimbus amount (tower built) from which it strikes
const SOUND := 343.0  # m/s
const DAMP_HOURS := 8
# Scenarios: weights by season (summer, autumn, winter, spring), then keys {genus: amount}.
const SCENARIOS := [
	[[4, 2, 1, 3], [{G.CU: 0.45, G.CI: 0.3}, {G.CU: 0.6, G.CI: 0.15}, {G.CU: 0.5, G.CI: 0.35}]],  # fair
	[[3, 1, 2, 2], [{G.CI: 0.25}, {}, {G.CU: 0.25}]],  # clear
	[[4, 1, 0.3, 2], [{G.CU: 0.35}, {G.CU: 0.65}, {G.CU: 0.8, G.CB: 0.45}, {G.CU: 0.5, G.CB: 1.0},
		{G.CU: 0.35, G.CB: 0.5, G.AC: 0.3}, {G.CU: 0.3, G.CI: 0.3}]],  # convective: cumulus → storm → clearing
	[[1, 3, 3, 2], [{G.CI: 0.6}, {G.CI: 0.4, G.CS: 0.6}, {G.CS: 0.7, G.AS: 0.6}, {G.AS: 0.85, G.NS: 0.5},
		{G.NS: 1.0, G.ST: 0.3}, {G.SC: 0.7, G.ST: 0.3}, {G.SC: 0.5, G.CU: 0.3}]],  # warm front
	[[2, 2, 1, 2], [{G.CC: 0.7, G.CI: 0.3}, {G.CC: 0.4, G.AC: 0.6}, {G.AC: 0.8}, {G.AC: 0.45, G.CU: 0.3}]],  # mackerel sky
	[[0.5, 3, 4, 1.5], [{G.ST: 0.8}, {G.ST: 0.6, G.SC: 0.5}, {G.SC: 0.8}, {G.SC: 0.55, G.CU: 0.2}]],  # grey
]
const PRESETS := [  # [HUD label, {genus: amount}]; 0 = auto
	["auto", {}], ["Cirrus", {G.CI: 0.8}], ["Cirrocumulus", {G.CC: 0.8}], ["Cirrostratus", {G.CS: 0.9}],
	["Altocumulus", {G.AC: 0.8}], ["Altostratus", {G.AS: 0.9}], ["Nimbostratus", {G.NS: 1.0}],
	["Stratocumulus", {G.SC: 0.8}], ["Stratus", {G.ST: 0.9}], ["Cumulus", {G.CU: 0.6}],
	["Cumulonimbus", {G.CB: 0.55, G.CU: 0.3}], ["Orage", {G.CB: 0.95, G.CU: 0.3}],
]

var world  # world.gd
var hours := 0.0  # daynight.hours() at the last update
var preset := 0
var amt := PackedFloat32Array()  # by G, at the player
var ahead := PackedFloat32Array()  # by G, LEAD hours later (shown upwind)
var wind := Vector2(0.92, 0.39)  # unit: where the clouds go
var storm := Vector2.ZERO  # world xz of the cumulonimbus
var storm_dist := STORM_FAR
var overcast := 0.0  # 0 clear .. 1 dark overcast overhead
var rain := 0.0  # precipitation at the player, 0..1 (≥ 0.5 = heavy)
var damp := 0.0  # 0..1, steady rain in the last DAMP_HOURS game hours: daynight.gd thickens the morning mist
var strobe := 0.0  # lightning flicker, 0..1 (the bolt)
var flash := 0.0  # its light on the scene: dimmer far away
var bolt := Vector3(0, 0, 99)  # last strike: world x, z and age (s)
var bolt_seed := 0.0
var thunder := []  # pending [seconds left, distance m]
var rng := RandomNumberGenerator.new()
var next_strike := 5.0
var rain_fx: CPUParticles3D
var thunder_player := AudioStreamPlayer.new()
var label := ""  # HUD text


func _ready() -> void:
	rng.seed = SEED
	_setup_rain()
	world.player.add_child(rain_fx)
	add_child(thunder_player)
	_process(0.0)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_N:
		set_preset(posmod(preset + (-1 if e.shift_pressed else 1), PRESETS.size()))


func set_preset(p: int) -> void:
	preset = p
	_process(0.0)


## Amounts by G for a game hour: the preset's, else the schedule's for the current season.
func target(h: float) -> PackedFloat32Array:
	if preset:
		return _amounts(PRESETS[preset][1], {}, 0.0)
	return state(h, world.seasons.season)


## The schedule (pure function of the hour and the season).
func state(h: float, season: int) -> PackedFloat32Array:
	var k := floori(h / SLOT)
	var keys: Array = scenario(k, season)[1]
	var f := fposmod(h, SLOT) / SLOT * keys.size()
	var i := int(f)
	var next: Dictionary = keys[i + 1] if i + 1 < keys.size() else scenario(k + 1, season)[1][0]
	return _amounts(keys[i], next, smoothstep(0.0, 1.0, f - i))


## Scenario of slot k: fair for the first slots, then a weighted pick seeded by k.
func scenario(k: int, season: int) -> Array:
	if k <= FAIR_SLOTS:
		return SCENARIOS[0]
	var r := RandomNumberGenerator.new()
	r.seed = hash(Vector2i(SEED, k))
	var total := 0.0
	for s in SCENARIOS:
		total += s[0][season]
	var x := r.randf() * total
	for s in SCENARIOS:
		x -= s[0][season]
		if x < 0.0:
			return s
	return SCENARIOS[0]


static func _amounts(a: Dictionary, b: Dictionary, t: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for g in G.size():
		out.append(lerpf(a.get(g, 0.0), b.get(g, 0.0), t))
	return out


func _process(delta: float) -> void:
	hours = world.daynight.hours()
	amt = target(hours)
	ahead = target(hours + LEAD)
	# The storm comes from upwind as it builds and leaves downwind as it decays: the side flips at its
	# peak, when it is overhead (distance 0), so it never jumps.
	storm_dist = (1.0 - amt[G.CB]) * STORM_FAR
	var side := 1.0 if target(hours + 0.05)[G.CB] < amt[G.CB] else -1.0
	var cam: Vector3 = world.player.camera.global_position
	storm = Vector2(cam.x, cam.z) + wind * side * storm_dist
	var under := smoothstep(STORM_BASE, STORM_BASE * 0.6, storm_dist) * float(amt[G.CB] > LIGHTNING_MIN)
	var clear := 1.0 - 0.9 * under
	for g in G.size():
		clear *= 1.0 - DIM[g] * amt[g]
	overcast = 1.0 - clear
	rain = maxf(smoothstep(0.4, 0.7, amt[G.NS]) * 0.45, under)
	damp = 0.0
	for i in range(1, DAMP_HOURS + 1):  # the schedule is a pure function of the hour: scrubbing included
		damp = maxf(damp, smoothstep(0.4, 0.7, target(hours - i)[G.NS]))
	_precipitate()
	_lightning(delta, cam)
	var names := []
	for g in G.size():
		if amt[g] > 0.15:
			names.append(NAMES[g])
	var text := "Météo (%s) : %s" % [PRESETS[preset][0], ", ".join(names) if names else "ciel clair"]
	if rain > 0.05:
		text += " · " + ("Neige" if winter() else ("Orage" if amt[G.CB] > LIGHTNING_MIN and under > 0.5 else "Pluie"))
	if text != label:
		label = text
		world._update_hud()


func winter() -> bool:
	return world.seasons.season == world.seasons.Season.WINTER


## Rain or (in winter) snow around the player while it precipitates; heavy rain = more drops.
func _precipitate() -> void:
	var snow: CPUParticles3D = world.seasons.snow
	var falling := rain > 0.05
	var drops := 4000 if rain > 0.5 else 1500
	if rain_fx.amount != drops:
		rain_fx.amount = drops
	# The iso camera is 100 m away: thicker streaks, or they fall between the pixels.
	rain_fx.mesh.size = Vector2(0.12, 1.2) if world.player.view == world.player.View.ISO else Vector2(0.02, 0.6)
	for pair in [[snow, falling and winter()], [rain_fx, falling and not winter()]]:
		if pair[0].emitting != pair[1]:
			pair[0].emitting = pair[1]
			pair[0].visible = pair[1]


## Strikes every few seconds while a cumulonimbus is built: somewhere under its base (the player's
## too when overhead). Flash: bright, then a weaker re-strike; thunder follows at the speed of sound.
func _lightning(delta: float, cam: Vector3) -> void:
	bolt.z += delta
	if amt[G.CB] > LIGHTNING_MIN and delta > 0.0:
		next_strike -= delta
		if next_strike <= 0.0:
			strike(storm + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, STORM_BASE * 0.6))
			next_strike = rng.randf_range(3.0, 10.0) * (1.0 if storm_dist < STORM_BASE else 2.0)
	var t := bolt.z
	var near := clampf(1.2 - Vector2(bolt.x - cam.x, bolt.y - cam.z).length() / 15000.0, 0.15, 1.0)
	strobe = minf(exp(-t / 0.06) + 0.6 * exp(-maxf(t - 0.16, 0.0) / 0.08) * float(t > 0.16), 1.0) if t < 1.0 else 0.0
	flash = strobe * near
	for i in range(thunder.size() - 1, -1, -1):
		thunder[i][0] -= delta
		if thunder[i][0] <= 0.0:
			var d: float = thunder[i][1]
			thunder_player.stream = preload("res://assets/sounds/thunder_near.wav") if d < 3000.0 \
				else preload("res://assets/sounds/thunder_far.wav")
			thunder_player.volume_db = -2.0 - d / 600.0
			thunder_player.pitch_scale = rng.randf_range(0.9, 1.1)
			thunder_player.play()
			thunder.remove_at(i)


func strike(at: Vector2) -> void:
	var cam: Vector3 = world.player.camera.global_position
	bolt = Vector3(at.x, at.y, 0.0)
	bolt_seed = rng.randf() * 100.0
	var d := at.distance_to(Vector2(cam.x, cam.z))
	if d < 15000.0:
		thunder.append([d / SOUND, d])


## Rain streaks (CPU particles like the snow: the web build has no GPU particles).
func _setup_rain() -> void:
	rain_fx = CPUParticles3D.new()
	rain_fx.amount = 1500
	rain_fx.lifetime = 1.6
	rain_fx.preprocess = 1.6
	rain_fx.local_coords = false
	rain_fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rain_fx.emission_box_extents = Vector3(30, 1, 30)
	rain_fx.position.y = 15.0
	rain_fx.direction = Vector3.DOWN
	rain_fx.spread = 3.0
	rain_fx.gravity = Vector3(1.0, -2.0, 0.4)  # a little wind
	rain_fx.initial_velocity_min = 9.0
	rain_fx.initial_velocity_max = 11.0
	var drop := QuadMesh.new()
	drop.size = Vector2(0.02, 0.6)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(world.seasons.colour("stone"), 0.45)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y  # upright streak facing the camera, all views
	mat.billboard_keep_scale = true
	drop.material = mat
	rain_fx.mesh = drop
	rain_fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rain_fx.emitting = false
	rain_fx.visible = false
