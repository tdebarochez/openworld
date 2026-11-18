extends Node
## Ambient sounds by place, heard from the player's ear (tools/make_sounds.py): water lapping on a lake
## shore (not on winter ice), the village bell ringing the hour by day from the nearest square, a
## forge's hammer at work, the bells and calls of a flock. One AudioStreamPlayer3D per kind (POOL in
## all), moved to the nearest source in range a few times a second, stopped when none is.

const LOOK := 0.5  # s between searches
const SHORE_R := 40.0  # m: lapping heard within this of open water
const BELL_R := 350.0
const FORGE_R := 60.0
const FLOCK_R := 70.0
const BELL_HOURS := Vector2i(7, 20)  # first and last hour rung
const WORK_HOURS := Vector2(7.5, 19.0)  # the smith at the anvil
const FLOCK_HOURS := Vector2(5.5, 22.0)  # flocks quiet at night
const TOLL := 2.6  # s between strokes
const POOL := 4

var world  # world.gd (the parent)
var water := AudioStreamPlayer3D.new()
var bell := AudioStreamPlayer3D.new()
var forge := AudioStreamPlayer3D.new()
var flock := AudioStreamPlayer3D.new()
var tolls := 0  # strokes still to ring this hour
var next_toll := 0.0
var _hour := -1  # floor of daynight.hours() at the last update
var _look := 0.0


func _ready() -> void:
	world = get_parent()
	# [player, stream, dB, metres at full volume, metres heard]
	for p in [[water, preload("res://assets/sounds/water_lap.wav"), -4.0, 4.0, SHORE_R + 10.0],
			[bell, preload("res://assets/sounds/bell.wav"), 2.0, 60.0, BELL_R + 50.0],
			[forge, preload("res://assets/sounds/forge.wav"), -2.0, 6.0, FORGE_R + 10.0],
			[flock, preload("res://assets/sounds/sheep.wav"), -3.0, 6.0, FLOCK_R + 10.0]]:
		var a: AudioStreamPlayer3D = p[0]
		a.stream = p[1]
		a.volume_db = p[2]
		a.unit_size = p[3]
		a.max_distance = p[4]
		add_child(a)
	bell.max_polyphony = 3  # strokes ring into each other


func _process(delta: float) -> void:
	if not world.player or not world.daynight:
		return
	_look -= delta
	if _look <= 0.0:
		_look = LOOK
		update(world.player.global_position)
	if tolls > 0:
		next_toll -= delta
		if next_toll <= 0.0:
			_toll()


## Moves each sound to its nearest source around `p` (or stops it), and starts the bell on the hour.
func update(p: Vector3) -> void:
	var dn = world.daynight
	var hour: float = dn.time
	var ice: bool = world.seasons.season == world.seasons.Season.WINTER
	_play(water, null if ice else shore(p))
	var near := _nearest_life(p)
	_play(forge, near.forge if WORK_HOURS.x < hour and hour < WORK_HOURS.y else null)
	var herd = near.flock if FLOCK_HOURS.x < hour and hour < FLOCK_HOURS.y else null
	if herd:
		var s: AudioStream = preload("res://assets/sounds/sheep.wav") if herd[1] == world.life.Animal.SHEEP \
			else preload("res://assets/sounds/cowbells.wav")
		if flock.stream != s:
			flock.stop()
			flock.stream = s
	_play(flock, herd[0] if herd else null)
	var h := floori(dn.hours())
	if _hour >= 0 and h > _hour and h % 24 >= BELL_HOURS.x and h % 24 <= BELL_HOURS.y:
		var sq = square(p)
		if sq != null:
			bell.position = sq
			tolls = (h + 11) % 12 + 1  # 13:00 → one stroke, noon → twelve
			_toll()
	_hour = h


func _toll() -> void:
	bell.play()
	tolls -= 1
	next_toll = TOLL


## Plays `a` at `at` (looping from a random point when it starts), or stops it for null.
func _play(a: AudioStreamPlayer3D, at) -> void:
	if at == null:
		if a.playing:
			a.stop()
		return
	a.position = at
	if not a.playing:
		a.play(randf() * a.stream.get_length())


## Nearest open water within SHORE_R of `p` (at the surface), searched in rings outwards; null if none.
func shore(p: Vector3):
	for r in range(0, int(SHORE_R) + 1, 4):
		var best = null
		for i in 16 if r > 0 else 1:
			var q := Vector2(p.x, p.z) + Vector2.from_angle(TAU * i / 16.0) * r
			if world.height(q.x, q.y) < world.WATER_LEVEL - 0.2:
				var w := Vector3(q.x, world.WATER_LEVEL, q.y)
				if best == null or w.distance_to(p) < best.distance_to(p):
					best = w
		if best != null:
			return best
	return null


## Nearest village square within BELL_R of `p` (the bell rings 8 m above it), or null.
func square(p: Vector3):
	var best = null
	for g in _squares_near(p, BELL_R):
		var s: Dictionary = world.village_site(g)
		if s.is_empty():
			continue
		var c := Vector3(s.centre.x, world.height(s.centre.x, s.centre.y) + 8.0, s.centre.y)
		if Vector2(c.x - p.x, c.z - p.z).length() < BELL_R and (best == null or c.distance_to(p) < best.distance_to(p)):
			best = c
	return best


## {"forge": position or null, "flock": [position, Animal] or null}: the nearest forge within FORGE_R
## and the nearest grazing animal within FLOCK_R of `p`.
func _nearest_life(p: Vector3) -> Dictionary:
	var out := {"forge": null, "flock": null}
	var fd := FORGE_R
	var ad := FLOCK_R
	for g in _squares_near(p, world.life.FLOCK_FAR + FLOCK_R):
		var life: Dictionary = world.life.village_life(g)
		if life.is_empty():
			continue
		if not life.forge.is_empty() and life.forge[0].distance_to(p) < fd:
			fd = life.forge[0].distance_to(p)
			out.forge = life.forge[0] + Vector3.UP
		for an in life.flock.get("animals", []):
			if an[0].distance_to(p) < ad:
				ad = an[0].distance_to(p)
				out.flock = [an[0] + Vector3.UP, life.flock.kind]
	return out


func _squares_near(p: Vector3, r: float) -> Array[Vector2i]:
	var g: float = world.VILLAGE_GRID
	var out: Array[Vector2i] = []
	for gx in range(floori((p.x - r) / g), floori((p.x + r) / g) + 1):
		for gz in range(floori((p.z - r) / g), floori((p.z + r) / g) + 1):
			out.append(Vector2i(gx, gz))
	return out
