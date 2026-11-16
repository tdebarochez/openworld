extends CharacterBody3D
## First-person walker. Movement uses physical keys, so ZQSD on AZERTY = WASD on QWERTY.

const SPEED := 8.0
const SPRINT_MULT := 2.5
const JUMP := 6.0
const SWIM_SPEED := 4.0
const SWIM_UP := 3.0
const FLOAT_DEPTH := 0.3  # body centre this far under the surface → eyes 0.4 m above it
const MOUSE_SENS := 0.003

var world: Node3D  # world.gd — used to keep the player inside existing zones
var camera := Camera3D.new()


func _ready() -> void:
	var cs := CollisionShape3D.new()
	cs.shape = CapsuleShape3D.new()
	add_child(cs)
	camera.position.y = 0.7
	add_child(camera)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
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
	var input := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var speed := (SWIM_SPEED if swimming else SPEED) * (SPRINT_MULT if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	var dir := (basis * Vector3(input.x, 0, input.y)).normalized() * speed
	velocity.x = dir.x
	velocity.z = dir.z
	var prev := global_position
	move_and_slide()
	# World bound: stepping into a cell with no zone is undone.
	if not world.zones.has(world.cell_of(global_position)):
		global_position.x = prev.x
		global_position.z = prev.z
