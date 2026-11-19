extends CharacterBody3D
## Walker. C cycles the view: first person → third person (camera behind, mouse orbits) →
## isometric. Movement uses physical keys, so ZQSD on AZERTY = WASD on QWERTY.

enum View { FIRST, THIRD, ISO }

const SPEED := 8.0
const SPRINT_MULT := 2.5
const JUMP := 6.0
const SWIM_SPEED := 4.0
const SWIM_UP := 3.0
const FLOAT_DEPTH := 0.3  # body centre this far under the surface → eyes 0.4 m above it
const MOUSE_SENS := 0.003
const THIRD_DIST := 5.0  # m behind the head; the spring arm pulls in when terrain or a house is in the way
# Isometric view: orthographic camera looking down 35.26° (true isometric) from the north-east-ish.
const ISO_PITCH := -0.6155  # -atan(1/sqrt(2))
const ISO_YAW := PI / 4.0
const ISO_DIST := 100.0  # m back along the view ray: high enough to clear the hills in front
const ISO_SHADOWS := 220.0  # sun shadow range from the camera in iso view (default 100 m ends before the player)
# Hen moves: Space in the air flaps, the left mouse button held while falling glides.
const FLAP := 4.5  # m/s up per wing beat (not added: mashing can't stack): +1 m at a jump's apex (v²/2g)
const MAX_FLAPS := 3  # per airtime, refilled on the ground and in water: a flutter onto a roof, not flight
const FLAP_ANIM := 0.4  # s of &"flap" after a jump or a wing beat
const GLIDE_FALL := -1.2  # m/s sink while gliding: ~12 m forward per metre down at GLIDE_SPEED
const GLIDE_BRAKE := 25.0  # m/s² easing a faster fall back to GLIDE_FALL (net 15 against gravity: -6 → -1.2 in 0.32 s)
const GLIDE_SPEED := 14.0  # m/s a glide speeds up to (faster if sprinting), keys or not
const GLIDE_STEER := 10.0  # m/s² horizontal: a glide keeps its momentum and turns gently
const AIR_STEER := 30.0  # m/s² of key control in the air: snappy, but momentum (a glide's) isn't lost
const AIR_DRAG := 1.5  # m/s² slowing the air momentum with no key held: a released glide carries on
const AIR_GRACE := 0.15  # s off the floor before move_state says fall/glide (slopes and bumps don't flicker)
# A gliding hen banks into its turns like a plane: atan(sideways acceleration / g), capped.
const BANK_MAX := 0.61  # rad (35°): GLIDE_STEER at full sideways pull would give 46°
const BANK_EASE := 5.0  # 1/s exponential easing in and out of the bank (63 % in 0.2 s)
const HEN_MIDDLE := 0.84  # m above the feet: the body's centre (tools/make_hen.py), the bank's pivot
# Pitch, with the mouse's up/down while gliding (mouse up = nose up): a dive trades height for speed,
# pulling up trades it back for height, and too slow the wings stall and the hen sinks. The glide's
# speed: d(speed)/dt = -g·sin(pitch) + (GLIDE_SPEED - speed)·(GLIDE_PULL or GLIDE_DRAG); its climb rate
# = speed·sin(pitch) + GLIDE_FALL, the lift fading out towards GLIDE_MIN (then it sinks at STALL_FALL).
const PITCH_UP := 0.45  # rad, nose up
const PITCH_DOWN := 0.7  # rad, nose down
const PITCH_SENS := 0.004  # rad per pixel of mouse motion
const PITCH_EASE := 6.0  # 1/s the hen's body follows the pitch (and levels out after the glide)
const GLIDE_MIN := 3.0  # m/s: stalled, no lift left (full lift from GLIDE_MIN + 4)
const GLIDE_MAX := 34.0  # m/s at the bottom of a long dive
const GLIDE_PULL := 2.5  # 1/s: slower than GLIDE_SPEED, a level glide picks up towards it (as before)…
const GLIDE_DRAG := 0.25  # 1/s: …faster (after a dive), drag brings it back down, slowly
const STALL_FALL := -5.0  # m/s sink with no lift left

var world: Node3D  # world.gd — used to keep the player inside existing zones
var camera := Camera3D.new()
var sfx := preload("res://audio.gd").new()  # music + footsteps/jump/land
var view := View.FIRST
var arm := SpringArm3D.new()  # third person: pitch pivot at the head, camera at its end
var tp_cam := Camera3D.new()
var iso_cam := Camera3D.new()
var avatar: Node3D = preload("res://assets/hen/hen.glb").instantiate()  # hen.gd; hidden in first person
var tilt := Node3D.new()  # the avatar's parent, at the hen's middle: rotation.z is the glide's bank
var ear := AudioListener3D.new()  # birds are heard from the player, not from a camera behind or far above
var fp_shadows := 0.0
## For the avatar's animations: idle, walk, run, flap, glide, fall or swim; set every physics frame.
var move_state: StringName = &"idle"
var flaps := MAX_FLAPS  # wing beats left in this airtime
var flap_time := 0.0  # s left of &"flap"
var air := 0.0  # s since the feet last touched the floor
var space_was := false  # Space held last frame: a flap needs a fresh press, holding it doesn't flutter
var mouse_free := false  # released with Escape
var glide_ok := true  # false for the click that takes the mouse back: it captures, it doesn't glide
var pitch := 0.0  # rad, nose up > 0: the glide's pitch, set with the mouse while gliding
var glide_speed := GLIDE_SPEED  # m/s the glide flies at (dives speed it up, climbs slow it down)
var was_gliding := false


func _ready() -> void:
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	add_child(cs)
	camera.position.y = 0.7
	camera.far = world.VIEW_DIST + 50.0  # nothing visible past the fog anyway
	add_child(camera)
	add_child(sfx)
	arm.position.y = 0.7
	arm.rotation.x = -0.35
	arm.spring_length = THIRD_DIST
	arm.margin = 0.3
	arm.add_excluded_object(get_rid())
	tp_cam.far = camera.far
	arm.add_child(tp_cam)
	add_child(arm)
	iso_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	iso_cam.size = 60.0  # m of world shown vertically; mouse wheel zooms
	iso_cam.far = ISO_DIST * 2.5
	iso_cam.top_level = true  # doesn't turn with the player
	iso_cam.rotation = Vector3(ISO_PITCH, ISO_YAW, 0)
	add_child(iso_cam)
	tilt.position.y = HEN_MIDDLE - 1.0
	avatar.position.y = -HEN_MIDDLE  # feet at the bottom of the collision capsule
	avatar.visible = false
	tilt.add_child(avatar)
	add_child(tilt)
	ear.position.y = 0.7
	add_child(ear)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_view(v: View) -> void:
	if v == view:
		return
	var sun: DirectionalLight3D = world.seasons.sun
	if view == View.ISO:
		sun.directional_shadow_max_distance = fp_shadows
	elif v == View.ISO:
		fp_shadows = sun.directional_shadow_max_distance
		sun.directional_shadow_max_distance = ISO_SHADOWS
	# Depth fog would grey out everything from 100 m up; the iso view only shows ~60 m around the player.
	world.seasons.env.fog_enabled = v != View.ISO
	world.set_lamp_fade(v != View.ISO)
	view = v
	camera.current = v == View.FIRST
	tp_cam.current = v == View.THIRD
	iso_cam.current = v == View.ISO
	avatar.visible = v != View.FIRST
	if v == View.FIRST:
		ear.clear_current()
	else:
		ear.make_current()
	_follow()


func _follow() -> void:
	iso_cam.global_position = global_position + iso_cam.basis.z * ISO_DIST


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_C:
		set_view(((view + 1) % View.size()) as View)
	elif view != View.FIRST and e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var k := 0.9 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1  # wheel zooms
		if view == View.ISO:
			iso_cam.size = clampf(iso_cam.size * k, 20.0, 120.0)
		else:
			arm.spring_length = clampf(arm.spring_length * k, 2.0, 15.0)
	elif e is InputEventMouseMotion and move_state == &"glide" and not mouse_free:
		# Gliding: the mouse's up/down pitches the hen (mouse up = nose up) instead of tilting the view.
		pitch = clampf(pitch - e.relative.y * PITCH_SENS, -PITCH_DOWN, PITCH_UP)
		if view != View.ISO:
			rotate_y(-e.relative.x * MOUSE_SENS)
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and view != View.ISO:
		rotate_y(-e.relative.x * MOUSE_SENS)
		if view == View.FIRST:
			camera.rotation.x = clampf(camera.rotation.x - e.relative.y * MOUSE_SENS, -1.5, 1.5)
		else:  # third person: tilt the arm, from just above the ground to well overhead
			arm.rotation.x = clampf(arm.rotation.x - e.relative.y * MOUSE_SENS, -1.3, 0.4)
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		mouse_free = true
	elif e is InputEventMouseButton and e.pressed:
		# Own bookkeeping rather than Input.mouse_mode, which headless (tests) never reports as captured.
		if e.button_index == MOUSE_BUTTON_LEFT:
			glide_ok = not mouse_free
		mouse_free = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	# Body centre below the surface = swimming (feet ~1 m under water).
	var swimming: bool = global_position.y < world.WATER_LEVEL
	var space := Input.is_physical_key_pressed(KEY_SPACE)
	var tap := space and not space_was
	space_was = space
	flap_time -= delta
	var gliding := false
	if swimming:
		flaps = MAX_FLAPS
		# Float with the head out; hold Space to rise and climb out onto the shore.
		var target: float = SWIM_UP if space else (world.WATER_LEVEL - FLOAT_DEPTH - global_position.y) * 3.0
		velocity.y = move_toward(velocity.y, target, 10.0 * delta)
	elif not is_on_floor():
		velocity += get_gravity() * delta
		if tap and flaps > 0:
			flaps -= 1
			velocity.y = maxf(velocity.y, FLAP)
			flap_time = FLAP_ANIM
			sfx.flap()
		# A glide starts falling and carries on while the button is held, climbing included.
		gliding = glide_ok and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and (velocity.y < 0.0 or was_gliding)
		if gliding:
			if not was_gliding:
				# Full lift from the start, even from a standstill jump (a stall only comes from pulling up).
				glide_speed = maxf(Vector2(velocity.x, velocity.z).length(), GLIDE_MIN + 4.0)
			# The pick-up only works nose level or down: climbing, it would fly for ever.
			var pull := GLIDE_PULL * (1.0 - smoothstep(0.0, 0.1, pitch))
			var settle := (GLIDE_SPEED - glide_speed) * (pull if glide_speed < GLIDE_SPEED else GLIDE_DRAG)
			glide_speed = clampf(glide_speed + (settle - 9.8 * sin(pitch)) * delta, GLIDE_MIN, GLIDE_MAX)
			var lift := smoothstep(GLIDE_MIN, GLIDE_MIN + 4.0, glide_speed)
			if lift < 0.5:  # stalling: the nose drops by itself
				pitch = move_toward(pitch, -0.15, (1.0 - lift) * delta)
			var climb := lerpf(STALL_FALL, GLIDE_FALL, lift) + glide_speed * sin(pitch) * lift
			if velocity.y < climb:  # above it (a wing beat's rise), gravity alone slows it down
				velocity.y = move_toward(velocity.y, climb, GLIDE_BRAKE * delta)
	else:
		flaps = MAX_FLAPS
		if space:
			velocity.y = JUMP
			flap_time = FLAP_ANIM
			sfx.jump()
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var speed := (SWIM_SPEED if swimming else SPEED) * (SPRINT_MULT if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	# Iso: keys follow the screen (up = away from the camera) and the player turns to face its way.
	var iso := view == View.ISO
	var dir := ((Basis(Vector3.UP, ISO_YAW) if iso else basis) * Vector3(input.x, 0, input.y)).normalized()
	if iso and dir:
		rotation.y = atan2(-dir.x, -dir.z)
	var h := Vector2(velocity.x, velocity.z)
	var bank := 0.0
	if gliding:  # momentum carries on at the glide's speed, the way the hen faces (or the keys steer)
		var want := (dir if dir else -global_basis.z) * glide_speed
		var was := h
		h = h.move_toward(Vector2(want.x, want.z), GLIDE_STEER * delta)
		# Turn rate of the flight path (not the body, which snaps in iso) × speed = sideways pull.
		# In (x, z) a positive angle_to is a right turn; a positive rotation.z lifts the right wing.
		bank = clampf(atan(-was.angle_to(h) / delta * h.length() / 9.8), -BANK_MAX, BANK_MAX)
		velocity.x = h.x
		velocity.z = h.y
	elif not swimming and not is_on_floor():  # air: keys steer, but a glide's speed isn't dropped on release
		var want := Vector2(dir.x, dir.z) * maxf(speed, h.length()) if dir else h.move_toward(Vector2.ZERO, AIR_DRAG * delta)
		h = h.move_toward(want, AIR_STEER * delta)
		velocity.x = h.x
		velocity.z = h.y
	else:
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	var prev := global_position
	move_and_slide()
	sfx.update(delta, is_on_floor(), swimming, Vector2(velocity.x, velocity.z).length())
	# World bound: stepping into a cell with no zone (or a light one, without collision yet) is undone.
	if not world.is_solid(world.cell_of(global_position)):
		global_position.x = prev.x
		global_position.z = prev.z
		velocity.x = 0.0  # a glide doesn't keep pushing into the edge
		velocity.z = 0.0
	air = 0.0 if is_on_floor() else air + delta
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	if swimming:
		move_state = &"swim"
	elif air > 0.0 and flap_time > 0.0:
		move_state = &"flap"
	elif air > AIR_GRACE:
		move_state = &"glide" if gliding else &"fall"
	elif ground_speed < 0.5:
		move_state = &"idle"
	else:
		move_state = &"run" if ground_speed > SPEED * 1.5 else &"walk"
	if iso:
		_follow()
	tilt.rotation.z = lerpf(tilt.rotation.z, bank, 1.0 - exp(-BANK_EASE * delta))
	if not gliding:  # next glide starts level-ish
		pitch = move_toward(pitch, 0.0, 1.5 * delta)
	tilt.rotation.x = lerpf(tilt.rotation.x, pitch if gliding else 0.0, 1.0 - exp(-PITCH_EASE * delta))
	was_gliding = gliding
	_animate()


## The hen's animation from move_state (it has no fall clip: a fast fall spreads the wings, a slow
## one — the top of a jump — keeps the current clip).
func _animate() -> void:
	var h := Vector2(velocity.x, velocity.z).length()
	match move_state:
		&"walk":
			avatar.play(&"walk", h / SPEED)
		&"run":
			avatar.play(&"run", h / (SPEED * SPRINT_MULT))
		&"fall":
			if velocity.y < -2.0:
				avatar.play(&"glide")
		_:  # idle, flap, glide, swim
			avatar.play(move_state)
