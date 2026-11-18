extends SceneTree
# Run: godot --headless --path . -s tests/test_moves.gd
# Hen moves on a flat platform high above the terrain: Space held on the ground jumps once (no
# flutter), a Space press in the air flaps (at most MAX_FLAPS per airtime, refilled on landing), the
# left mouse button held while falling glides (sink capped, lands further than a plain jump), and
# move_state follows along.

var w
var p


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)
	_run()


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.keycode = code
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _mouse(down: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _tap_space() -> void:
	_key(KEY_SPACE, true)
	await physics_frame
	_key(KEY_SPACE, false)


## Puts the player at `spot` (on the platform), facing -Z, and waits for it to stand still.
func _place(spot: Vector3) -> void:
	p.global_position = spot
	p.rotation = Vector3.ZERO
	p.velocity = Vector3.ZERO
	await _frames(2)
	for i in 120:
		if p.is_on_floor():
			break
		await physics_frame
	await _frames(5)
	assert(p.is_on_floor(), "not standing on the platform")


## Jumps (Space tapped, held for `hold` frames) with `flaps` wing beats at the apexes, holding `keys`
## and the mouse button if `glide`. Returns [highest point above the start, horizontal distance].
func _jump(flaps: int, keys: Array = [], glide := false, hold := 1) -> Array:
	var start: Vector3 = p.global_position
	for k in keys:
		_key(k, true)
	if glide:
		_mouse(true)
	_key(KEY_SPACE, true)
	await _frames(hold)
	_key(KEY_SPACE, false)
	var top := 0.0
	var done := 0
	var sink_checked := false
	for i in 900:
		await physics_frame
		top = maxf(top, p.global_position.y - start.y)
		if p.is_on_floor():
			break
		if done < flaps and p.velocity.y <= 0.0:  # flap at the apex
			await _tap_space()
			done += 1
			if done <= p.MAX_FLAPS:
				assert(p.velocity.y > p.FLAP - 0.5, "a flap should raise the vertical speed, got %f" % p.velocity.y)
				assert(p.move_state == &"flap")
			else:
				assert(p.velocity.y < 0.0, "flapped past MAX_FLAPS")
		if glide and p.velocity.y < 0.0 and p.flap_time < -0.4:  # well into the glide
			assert(p.velocity.y > p.GLIDE_FALL - 0.05, "glide sinks too fast: %f" % p.velocity.y)
			assert(p.move_state == &"glide", "state %s" % p.move_state)
			sink_checked = true
		elif not glide and p.velocity.y < -3.0:
			assert(p.move_state == &"fall", "state %s" % p.move_state)
	for k in keys:
		_key(k, false)
	if glide:
		_mouse(false)
		assert(sink_checked, "never glided")
	await _frames(3)
	assert(p.is_on_floor(), "no landing")
	assert(p.flaps == p.MAX_FLAPS, "flaps not refilled on landing")
	var moved: Vector3 = p.global_position - start
	return [top, Vector2(moved.x, moved.z).length()]


func _run() -> void:
	await physics_frame  # world _ready (which creates the player) runs once the tree starts
	p = w.player
	for i in 1200:  # wait for the origin zone to be built (with collision), or every step is undone
		if w.is_solid(w.cell_of(Vector3.ZERO)):
			break
		await physics_frame
	assert(w.is_solid(w.cell_of(Vector3.ZERO)), "origin zone never built")
	var floor := StaticBody3D.new()  # flat, nothing in the way, far above any hill
	var box := CollisionShape3D.new()
	box.shape = BoxShape3D.new()
	box.shape.size = Vector3(80, 1, 80)
	floor.add_child(box)
	floor.position = Vector3(0, 200, 0)
	root.add_child(floor)
	var spot := Vector3(0, 202, 25)

	await _place(spot)
	assert(p.move_state == &"idle", "state %s" % p.move_state)
	_key(KEY_W, true)
	await _frames(10)
	assert(p.move_state == &"walk", "state %s" % p.move_state)
	_key(KEY_SHIFT, true)
	await _frames(10)
	assert(p.move_state == &"run", "state %s" % p.move_state)
	_key(KEY_SHIFT, false)
	_key(KEY_W, false)

	# Holding Space on the ground jumps once: no flutter while it stays down in the air.
	await _place(spot)
	var y0: float = p.global_position.y
	_key(KEY_SPACE, true)
	await _frames(2)
	assert(p.move_state == &"flap" and p.velocity.y > 0.0)
	var top := 0.0
	for i in 60:  # past the apex and down again, Space still held
		await physics_frame
		top = maxf(top, p.global_position.y - y0)
		if p.is_on_floor():
			break
	assert(p.flaps == p.MAX_FLAPS and top < 2.0, "held Space fluttered (%d flaps left, %f m)" % [p.flaps, top])
	_key(KEY_SPACE, false)
	await _place(spot)
	var heights := []
	for n in p.MAX_FLAPS + 2:
		var r: Array = await _jump(n)
		heights.append(r[0])
		await _place(spot)
	print("jump height with 0..%d flaps: %s" % [heights.size() - 1, heights])
	assert(absf(heights[0] - 1.84) < 0.15, "plain jump %f m" % heights[0])
	for n in range(1, p.MAX_FLAPS + 1):
		assert(heights[n] > heights[n - 1] + 0.5, "flap %d didn't lift" % n)
	assert(absf(heights[p.MAX_FLAPS + 1] - heights[p.MAX_FLAPS]) < 0.1, "more than MAX_FLAPS flaps")

	# Gliding from the same spot, same keys, lands further.
	var plain: Array = await _jump(0, [KEY_W])
	await _place(spot)
	var glide: Array = await _jump(0, [KEY_W], true)
	await _place(spot)
	var high: Array = await _jump(p.MAX_FLAPS, [KEY_W], true)
	await _place(spot)
	var drift: Array = await _jump(0, [], true)  # no keys: drifts forward on its own
	print("distance: plain jump %.1f m, glide %.1f m, glide after %d flaps %.1f m, glide without keys %.1f m" % [
		plain[1], glide[1], p.MAX_FLAPS, high[1], drift[1]])
	assert(glide[1] > plain[1] * 1.2, "glide not further")
	assert(high[1] > glide[1] * 1.5)
	assert(drift[1] > 2.0)

	# The click that takes the mouse back after Escape doesn't glide.
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	_mouse(true)
	_mouse(false)
	assert(not p.glide_ok)
	_mouse(true)
	_mouse(false)
	assert(p.glide_ok)
	print("MOVES OK")
	quit()
