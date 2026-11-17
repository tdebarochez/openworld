extends SceneTree
# Run: godot --headless --path . -s tests/test_audio.gd
# Footstep cadence, landing detection, one looping music per season and the crossfade on a switch.

var a
var frames := 0


func _initialize() -> void:
	a = load("res://audio.gd").new()
	a.seasons = load("res://seasons.gd").new()  # stands in for the world's
	root.add_child(a)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 1:  # after a's _ready
		_check_sounds()
		a.seasons.season = a.seasons.Season.WINTER  # as seasons.set_season() would
	elif frames == 3:  # a's _process has seen the switch
		assert(a.music.stream == a.MUSIC[a.seasons.Season.WINTER], "winter loop not started")
		assert(a.fading.stream == a.MUSIC[a.seasons.Season.SUMMER] and a.fading.playing, "summer not fading out")
		a.tween.custom_step(a.FADE + 0.1)  # skip to the end of the crossfade
		assert(a.music.playing and absf(a.music.volume_db - a.MUSIC_DB) < 0.01, "winter not at full volume")
		assert(not a.fading.playing, "summer still playing")
		a.seasons.free()
		print("AUDIO OK")
		quit()
	return false


func _check_sounds() -> void:
	for s: int in a.seasons.Season.values():  # each season has its own looping stream
		var wav: AudioStreamWAV = a.MUSIC[s]
		assert(wav.loop_mode == AudioStreamWAV.LOOP_FORWARD, "music does not loop")
		assert(a.MUSIC.count(wav) == 1, "two seasons share a loop")
		print("music %d: %.1f s, loop %d..%d" % [s, wav.get_length(), wav.loop_begin, wav.loop_end])
	assert(a.music.stream == a.MUSIC[a.seasons.Season.SUMMER] and a.music.playing)

	var walk := _count(8.0, true, false)
	var sprint := _count(20.0, true, false)
	print("steps per 10 s: walk ", walk, ", sprint ", sprint)
	assert(walk >= 25 and walk <= 32)
	assert(sprint > walk + 8)
	assert(_count(0.0, true, false) == 0)   # standing still
	assert(_count(8.0, false, false) == 0)  # airborne
	assert(_count(8.0, true, true) == 0)    # swimming

	a.update(0.1, false, false, 0.0)  # small bump: no thud
	assert(a.update(1 / 60.0, true, false, 0.0) == &"")
	a.jump()  # landing after a jump always thuds
	assert(a.update(1 / 60.0, true, false, 8.0) == &"land")
	for i in 40:
		a.update(1 / 60.0, false, false, 0.0)
	assert(a.update(1 / 60.0, true, false, 0.0) == &"land")


func _count(speed: float, grounded: bool, swimming: bool) -> int:
	a.update(1 / 60.0, true, false, 0.0)  # reset: standing on the ground
	var n := 0
	for i in 600:
		n += int(a.update(1 / 60.0, grounded, swimming, speed) == &"step")
	return n
