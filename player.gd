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

var world: Node3D  # world.gd — used to keep the player inside existing zones
var camera := Camera3D.new()
var sfx := preload("res://audio.gd").new()  # music + footsteps/jump/land
var view := View.FIRST
var arm := SpringArm3D.new()  # third person: pitch pivot at the head, camera at its end
var tp_cam := Camera3D.new()
var iso_cam := Camera3D.new()
var avatar: Node3D = preload("res://assets/hen/hen.glb").instantiate()  # hen.gd; hidden in first person
var ear := AudioListener3D.new()  # birds are heard from the player, not from a camera behind or far above
var fp_shadows := 0.0


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
	avatar.position.y = -1.0  # feet at the bottom of the collision capsule
	avatar.visible = false
	add_child(avatar)
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
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and view != View.ISO:
		rotate_y(-e.relative.x * MOUSE_SENS)
		if view == View.FIRST:
			camera.rotation.x = clampf(camera.rotation.x - e.relative.y * MOUSE_SENS, -1.5, 1.5)
		else:  # third person: tilt the arm, from just above the ground to well overhead
			arm.rotation.x = clampf(arm.rotation.x - e.relative.y * MOUSE_SENS, -1.3, 0.4)
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	# Body centre below the surface = swimming (feet ~1 m under water).
	var swimming: bool = global_position.y < world.WATER_LEVEL
	if swimming:
		# Float with the head out; hold Space to rise and climb out onto the shore.
		var target: float = SWIM_UP if Input.is_physical_key_pressed(KEY_SPACE) \
			else (world.WATER_LEVEL - FLOAT_DEPTH - global_position.y) * 3.0
		velocity.y = move_toward(velocity.y, target, 10.0 * delta)
	elif not is_on_floor():
		velocity += get_gravity() * delta
	elif Input.is_physical_key_pressed(KEY_SPACE):
		velocity.y = JUMP
		sfx.jump()
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var speed := (SWIM_SPEED if swimming else SPEED) * (SPRINT_MULT if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	# Iso: keys follow the screen (up = away from the camera) and the player turns to face its way.
	var iso := view == View.ISO
	var dir := ((Basis(Vector3.UP, ISO_YAW) if iso else basis) * Vector3(input.x, 0, input.y)).normalized() * speed
	if iso and dir:
		rotation.y = atan2(-dir.x, -dir.z)
	velocity.x = dir.x
	velocity.z = dir.z
	var prev := global_position
	move_and_slide()
	sfx.update(delta, is_on_floor(), swimming, Vector2(velocity.x, velocity.z).length())
	# World bound: stepping into a cell with no zone (or a light one, without collision yet) is undone.
	if not world.is_solid(world.cell_of(global_position)):
		global_position.x = prev.x
		global_position.z = prev.z
	if iso:
		_follow()
	_animate()


## The hen's animation from what the body is doing.
func _animate() -> void:
	var h := Vector2(velocity.x, velocity.z).length()
	if global_position.y < world.WATER_LEVEL or is_on_floor() and h < 0.5:  # swimming or standing
		avatar.play(&"idle")
	elif is_on_floor():
		if h < SPEED * (1.0 + SPRINT_MULT) / 2.0:
			avatar.play(&"walk", h / SPEED)
		else:
			avatar.play(&"run", h / (SPEED * SPRINT_MULT))
	elif velocity.y > 0.5:
		avatar.play(&"flap")
	elif velocity.y < -2.0:
		avatar.play(&"glide")
	# else around the top of a jump, or off a small step: keep the current one
