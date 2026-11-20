extends SceneTree
# Run: godot --headless --path . -s tests/test_moves.gd
# Hen moves on a flat platform high above the terrain: Space held on the ground jumps once (no
# flutter), a Space press in the air flaps (at most MAX_FLAPS per airtime, refilled on landing), a
# falling hen glides by itself once its wings stop beating (sink capped, lands further than a
# ballistic jump, banks into turns), and move_state follows along.

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


func _motion(dy: float) -> void:  # mouse moved down by dy pixels (up if negative)
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(0, dy)
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


## Jumps (Space tapped, held for `hold` frames) with `flaps` wing beats at the apexes, holding `keys`,
## and glides down. Returns [highest point above the start, horizontal distance].
func _jump(flaps: int, keys: Array = [], hold := 1) -> Array:
	var start: Vector3 = p.global_position
	for k in keys:
		_key(k, true)
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
		if p.velocity.y < 0.0 and p.flap_time < -0.4:  # well into the glide
			assert(p.velocity.y > p.GLIDE_FALL - 0.05, "glide sinks too fast: %f" % p.velocity.y)
			assert(p.move_state == &"glide", "state %s" % p.move_state)
			sink_checked = true
	for k in keys:
		_key(k, false)
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
	box.shape.size = Vector3(400, 1, 400)  # a glide after three flaps goes ~100 m
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

	# Gliding (no click: it comes by itself) lands further than a ballistic jump would.
	var plain: float = p.SPEED * 2.0 * p.JUMP / 9.8
	var glide: Array = await _jump(0, [KEY_W])
	await _place(spot)
	var high: Array = await _jump(p.MAX_FLAPS, [KEY_W])
	await _place(spot)
	var drift: Array = await _jump(0, [])  # no keys: drifts forward on its own
	print("distance: ballistic jump %.1f m, glide %.1f m, glide after %d flaps %.1f m, glide without keys %.1f m" % [
		plain, glide[1], p.MAX_FLAPS, high[1], drift[1]])
	assert(glide[1] > plain * 1.2, "glide not further")
	assert(high[1] > glide[1] * 1.5)
	assert(drift[1] > 2.0)

	# A wing beat in mid-glide (no keys) interrupts it but keeps its speed, and the glide comes back.
	p.global_position = spot + Vector3(0, 30, 0)
	p.velocity = Vector3.ZERO
	await _frames(90)
	assert(p.move_state == &"glide", "state %s" % p.move_state)
	var gliding_speed := Vector2(p.velocity.x, p.velocity.z).length()
	await _tap_space()
	await _frames(10)
	assert(p.move_state == &"flap", "state %s" % p.move_state)
	var after := Vector2(p.velocity.x, p.velocity.z).length()
	print("glide speed %.1f m/s, 10 frames into a wing beat %.1f m/s" % [gliding_speed, after])
	assert(gliding_speed > p.SPEED and after > gliding_speed * 0.9, "momentum lost on a wing beat")
	await _frames(60)
	assert(p.move_state == &"glide", "glide didn't resume, state %s" % p.move_state)
	for i in 600:
		if p.is_on_floor():
			break
		await physics_frame

	# A gliding hen banks into its turns (the mouse turns the body; right = right wing down, i.e. a
	# negative tilt.rotation.z), more in a hard turn, capped, and levels out once the turn stops.
	p.global_position = spot + Vector3(0, 30, 0)
	p.velocity = Vector3.ZERO
	await _frames(90)
	var straight: float = p.tilt.rotation.z
	var banks := {}
	# rad/s of body turn, frames. The flight path lags a hard turn (GLIDE_STEER), so it levels later.
	for turn in [[&"gentle right", -0.3, 90], [&"hard left", 1.2, 90], [&"level", 0.0, 180]]:
		var peak := 0.0
		for i in turn[2]:
			p.rotate_y(turn[1] / 60.0)
			await physics_frame
			assert(p.move_state == &"glide", "state %s" % p.move_state)
			peak = maxf(peak, absf(p.tilt.rotation.z))
		assert(peak <= p.BANK_MAX + 0.001, "bank %f past the cap" % peak)
		banks[turn[0]] = p.tilt.rotation.z
	print("bank: straight %.3f, gentle right %.3f, hard left %.3f, 3 s after %.3f rad" % [
		straight, banks[&"gentle right"], banks[&"hard left"], banks[&"level"]])
	assert(absf(straight) < 0.01, "banked flying straight")
	assert(banks[&"gentle right"] < -0.2, "no right bank")
	assert(banks[&"hard left"] > -banks[&"gentle right"] + 0.1, "no (harder) left bank")
	assert(absf(banks[&"level"]) < 0.02, "didn't level out")
	# Iso view: the body snaps to the keys, the bank follows the flight path. W then W+D = a right turn.
	p.set_view(p.View.ISO)
	_key(KEY_W, true)
	await _frames(60)
	_key(KEY_D, true)
	await _frames(20)
	var iso_bank: float = p.tilt.rotation.z
	_key(KEY_D, false)
	_key(KEY_W, false)
	p.set_view(p.View.FIRST)
	print("iso bank turning right %.3f rad" % iso_bank)
	assert(iso_bank < -0.2, "no right bank in iso")
	for i in 600:
		if p.is_on_floor():
			break
		await physics_frame
	await _frames(60)
	assert(p.is_on_floor() and absf(p.tilt.rotation.z) < 0.01, "banked on the ground")

	# Pitch with the mouse while gliding: a dive speeds up and sinks faster, pulling up out of it climbs
	# and slows down, a long climb stalls and sinks; on the ground the pitch levels out again.
	p.global_position = spot + Vector3(0, 120, 0)
	p.velocity = Vector3.ZERO
	p.rotation = Vector3.ZERO
	await _frames(60)
	assert(p.move_state == &"glide", "state %s" % p.move_state)
	var level_speed: float = p.glide_speed
	var level_sink: float = p.velocity.y
	_motion(150)  # mouse down: nose down
	assert(p.pitch < -0.5, "mouse down should dive, pitch %f" % p.pitch)
	await _frames(60)
	print("level %.1f m/s sinking %.1f; dive %.1f m/s sinking %.1f" % [level_speed, level_sink, p.glide_speed, p.velocity.y])
	assert(p.glide_speed > level_speed + 4.0 and p.velocity.y < level_sink - 4.0, "a dive should be faster and steeper")
	assert(p.tilt.rotation.x < -0.3, "the hen's nose should point down")
	var fast: float = p.glide_speed
	_motion(-300)  # mouse up: nose up
	await _frames(75)  # the pull-out takes about a second
	assert(p.velocity.y > 0.0, "pulling up out of a dive should climb, got %f" % p.velocity.y)
	assert(p.tilt.rotation.x > 0.2)
	await _frames(240)
	assert(p.glide_speed < fast and p.velocity.y < 0.0, "a long climb should slow down and stall")
	for i in 900:
		if p.is_on_floor():
			break
		await physics_frame
	await _frames(90)
	assert(absf(p.pitch) < 0.05 and absf(p.tilt.rotation.x) < 0.05, "pitch not levelled after landing")

	# Escape frees the mouse, a click takes it back.
	_key(KEY_ESCAPE, true)
	_key(KEY_ESCAPE, false)
	assert(p.mouse_free)
	_mouse(true)
	_mouse(false)
	assert(not p.mouse_free)
	print("MOVES OK")
	quit()
