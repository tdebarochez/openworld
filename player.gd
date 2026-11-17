extends CharacterBody3D
## Walker, seen in first person or (V) from an isometric camera. Movement uses physical keys,
## so ZQSD on AZERTY = WASD on QWERTY.

const SPEED := 8.0
const SPRINT_MULT := 2.5
const JUMP := 6.0
const SWIM_SPEED := 4.0
const SWIM_UP := 3.0
const FLOAT_DEPTH := 0.3  # body centre this far under the surface → eyes 0.4 m above it
const MOUSE_SENS := 0.003
# Isometric view (V): orthographic camera looking down 35.26° (true isometric) from the north-east-ish.
const ISO_PITCH := -0.6155  # -atan(1/sqrt(2))
const ISO_YAW := PI / 4.0
const ISO_DIST := 100.0  # m back along the view ray: high enough to clear the hills in front
const ISO_SHADOWS := 220.0  # sun shadow range from the camera in iso view (default 100 m ends before the player)

var world: Node3D  # world.gd — used to keep the player inside existing zones
var camera := Camera3D.new()
var sfx := preload("res://audio.gd").new()  # music + footsteps/jump/land
var iso := false
var iso_cam := Camera3D.new()
var avatar := MeshInstance3D.new()  # only shown in iso view
var ear := AudioListener3D.new()  # birds are heard from the player, not from the far iso camera
var fp_shadows := 0.0


func _ready() -> void:
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	add_child(cs)
	camera.position.y = 0.7
	camera.far = world.VIEW_DIST + 50.0  # nothing visible past the fog anyway
	add_child(camera)
	add_child(sfx)
	iso_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	iso_cam.size = 60.0  # m of world shown vertically; mouse wheel zooms
	iso_cam.far = ISO_DIST * 2.5
	iso_cam.top_level = true  # doesn't turn with the player
	iso_cam.rotation = Vector3(ISO_PITCH, ISO_YAW, 0)
	add_child(iso_cam)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.3, 0.2)
	avatar.mesh = CapsuleMesh.new()  # same size as the collision capsule
	avatar.material_override = mat
	var nose := MeshInstance3D.new()  # shows which way the player faces
	nose.mesh = BoxMesh.new()
	nose.mesh.size = Vector3(0.3, 0.2, 0.4)
	nose.position = Vector3(0, 0.55, -0.5)
	avatar.add_child(nose)
	avatar.visible = false
	add_child(avatar)
	ear.position.y = 0.7
	add_child(ear)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func set_iso(on: bool) -> void:
	if on == iso:
		return
	iso = on
	iso_cam.current = on
	camera.current = not on
	avatar.visible = on
	if on:
		ear.make_current()
		fp_shadows = world.seasons.sun.directional_shadow_max_distance
	else:
		ear.clear_current()
	world.seasons.sun.directional_shadow_max_distance = ISO_SHADOWS if on else fp_shadows
	# Depth fog would grey out everything from 100 m up; the iso view only shows ~60 m around the player.
	world.seasons.env.fog_enabled = not on
	_follow()


func _follow() -> void:
	iso_cam.global_position = global_position + iso_cam.basis.z * ISO_DIST


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_V:
		set_iso(not iso)
	elif iso and e is InputEventMouseButton and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		iso_cam.size = clampf(iso_cam.size * (0.9 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 20.0, 120.0)
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not iso:
		rotate_y(-e.relative.x * MOUSE_SENS)
		camera.rotation.x = clampf(camera.rotation.x - e.relative.y * MOUSE_SENS, -1.5, 1.5)
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
	var dir := ((Basis(Vector3.UP, ISO_YAW) if iso else basis) * Vector3(input.x, 0, input.y)).normalized() * speed
	if iso and dir:
		rotation.y = atan2(-dir.x, -dir.z)
	velocity.x = dir.x
	velocity.z = dir.z
	var prev := global_position
	move_and_slide()
	sfx.update(delta, is_on_floor(), swimming, Vector2(velocity.x, velocity.z).length())
	# World bound: stepping into a cell with no zone is undone.
	if not world.zones.has(world.cell_of(global_position)):
		global_position.x = prev.x
		global_position.z = prev.z
	if iso:
		_follow()
