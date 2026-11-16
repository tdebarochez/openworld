extends SceneTree
# Run: godot --headless --path . -s tests/test_audio.gd
# Footstep cadence, landing detection and the music loop flag.

var a


func _initialize() -> void:
	a = load("res://audio.gd").new()
	root.add_child(a)


func _process(_delta: float) -> bool:  # first frame, after a's _ready
	var wav: AudioStreamWAV = a.music.stream
	assert(wav.loop_mode == AudioStreamWAV.LOOP_FORWARD, "music does not loop")
	print("music %.1f s, loop %d..%d" % [wav.get_length(), wav.loop_begin, wav.loop_end])

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
	print("AUDIO OK")
	quit()
	return true


func _count(speed: float, grounded: bool, swimming: bool) -> int:
	a.update(1 / 60.0, true, false, 0.0)  # reset: standing on the ground
	var n := 0
	for i in 600:
		n += int(a.update(1 / 60.0, grounded, swimming, speed) == &"step")
	return n
