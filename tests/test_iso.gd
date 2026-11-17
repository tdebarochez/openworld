extends SceneTree
# Run: godot --headless --path . -s tests/test_iso.gd
# V toggles an orthographic isometric camera that keeps the player in the middle of the screen,
# moves with the screen axes, and switching back restores the first-person view.

var w
var frames := 0
var start: Vector3


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _key(code: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = down
	Input.parse_input_event(e)
	Input.flush_buffered_events()  # deliver now, not at the next frame


func _physics_process(_delta: float) -> bool:
	frames += 1
	var p = w.player
	if frames == 30:  # landed
		var fog: bool = w.seasons.env.fog_enabled
		var shadows: float = w.seasons.sun.directional_shadow_max_distance
		_key(KEY_V, true)
		_key(KEY_V, false)
		assert(p.iso and p.iso_cam.current and p.avatar.visible)
		assert(p.iso_cam.projection == Camera3D.PROJECTION_ORTHOGONAL)
		assert(not w.seasons.env.fog_enabled)
		assert(w.seasons.sun.directional_shadow_max_distance > p.ISO_DIST)
		# The player sits on the camera's view axis, so it is drawn in the middle of the screen.
		var to_player: Vector3 = p.global_position - p.iso_cam.global_position
		assert(to_player.normalized().is_equal_approx(-p.iso_cam.global_basis.z))
		start = p.global_position
		_key(KEY_W, true)
	elif frames == 60:
		_key(KEY_W, false)
		# Forward = screen up = away from the camera on the ground.
		var moved: Vector3 = p.global_position - start
		var away: Vector3 = -p.iso_cam.global_basis.z
		away.y = 0
		assert(Vector2(moved.x, moved.z).normalized().dot(Vector2(away.x, away.z).normalized()) > 0.95, "moved %s" % moved)
		assert((p.global_position - p.iso_cam.global_position).normalized().is_equal_approx(-p.iso_cam.global_basis.z))
		p.set_iso(false)
		assert(p.camera.current and not p.avatar.visible and w.seasons.env.fog_enabled)
		assert(w.seasons.sun.directional_shadow_max_distance < p.ISO_DIST + 1.0)
		print("ISO OK")
		quit()
	return false
