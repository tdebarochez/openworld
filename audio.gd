extends Node
## Background music (one loop per season, crossfaded on a switch) and player sounds (all from
## tools/make_sounds.py). The player calls jump() and update() every physics frame; update() decides on
## steps and landings.

const MUSIC: Array[AudioStream] = [  # indexed by seasons.gd's Season; loop via the WAVs' smpl chunk
	preload("res://assets/sounds/music_summer.wav"), preload("res://assets/sounds/music_autumn.wav"),
	preload("res://assets/sounds/music_winter.wav"), preload("res://assets/sounds/music_spring.wav")]
const MUSIC_DB := -10.0
const FADE := 2.5  # s, season crossfade
const STEPS: Array[AudioStream] = [
	preload("res://assets/sounds/step_1.wav"), preload("res://assets/sounds/step_2.wav"),
	preload("res://assets/sounds/step_3.wav"), preload("res://assets/sounds/step_4.wav")]
const LAND_AIR_TIME := 0.35  # s off the ground before touching down thuds (ignores small bumps)

var music := AudioStreamPlayer.new()  # the current season's loop
var fading := AudioStreamPlayer.new()  # the previous season's, fading out
var seasons  # seasons.gd, through the player's world (tests set it themselves)
var season := 0  # whose loop `music` plays
var tween: Tween
var steps := AudioStreamPlayer.new()  # steps never overlap (0.22 s sound, ≥0.24 s apart)
var fx := AudioStreamPlayer.new()  # jump / land, ≥0.35 s apart
var stride_left := 0.0  # metres until the next footstep
var air_time := 0.0
var last_step := -1


func _ready() -> void:
	if "world" in get_parent():
		seasons = get_parent().world.seasons
	music.stream = MUSIC[season]
	music.volume_db = MUSIC_DB
	music.autoplay = true  # web: Godot resumes the browser's AudioContext on the first click/key
	music.process_mode = PROCESS_MODE_ALWAYS  # plays on in the pause menu (steps and fx pause)
	fading.process_mode = PROCESS_MODE_ALWAYS
	for p in [music, fading, steps, fx]:
		add_child(p)


func _process(_delta: float) -> void:
	if seasons and seasons.season != season:
		crossfade(seasons.season)


## Swaps the two music players: the new loop fades in from its start while the old one fades out.
func crossfade(s: int) -> void:
	season = s
	var old := music
	music = fading
	fading = old
	music.stream = MUSIC[s]
	music.volume_linear = 0.0
	music.play()
	if tween:
		tween.kill()  # mid-fade switch: the old loop fades on from where it is
	tween = create_tween().set_parallel()
	tween.tween_property(music, "volume_linear", db_to_linear(MUSIC_DB), FADE)
	tween.tween_property(fading, "volume_linear", 0.0, FADE)
	tween.chain().tween_callback(fading.stop)


## Metres per footstep: longer strides at speed, so cadence goes ~2.8 steps/s walking → ~4.2 sprinting.
static func stride(speed: float) -> float:
	return 1.6 + 0.16 * speed


## Returns &"step", &"land" or &"" (for tests).
func update(delta: float, grounded: bool, swimming: bool, speed: float) -> StringName:
	if swimming:
		air_time = 0.0
		stride_left = 0.0
		return &""
	if not grounded:
		air_time += delta
		return &""
	var landed := air_time > LAND_AIR_TIME
	air_time = 0.0
	if landed:
		stride_left = stride(speed)
		_play(fx, preload("res://assets/sounds/land.wav"), -4.0)
		return &"land"
	if speed < 0.5:
		stride_left = 0.0  # the first step after standing still comes right away
		return &""
	stride_left -= speed * delta
	if stride_left > 0.0:
		return &""
	stride_left += stride(speed)
	last_step = (last_step + 1 + randi() % (STEPS.size() - 1)) % STEPS.size()  # never the same twice
	_play(steps, STEPS[last_step], randf_range(-9.0, -6.0))
	return &"step"


func jump() -> void:
	air_time = LAND_AIR_TIME + 0.01  # a jump always ends with a landing thud, even onto a ledge
	_play(fx, preload("res://assets/sounds/jump.wav"), -6.0)


func flap() -> void:
	_play(fx, preload("res://assets/sounds/flap.wav"), -8.0)


func _play(p: AudioStreamPlayer, s: AudioStream, db: float) -> void:
	p.stream = s
	p.volume_db = db
	p.pitch_scale = randf_range(0.9, 1.1)
	p.play()
