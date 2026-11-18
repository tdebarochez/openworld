extends SceneTree
# Run: godot --headless --path . -s tests/test_views.gd
# C cycles first person → third person → isometric → first person. Third person: camera behind and
# above the head, keys move along the player's facing. Iso: orthographic camera keeping the player in
# the middle of the screen, keys follow the screen axes. Back in first person, fog and shadows return.

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


func _press_c() -> void:
	_key(KEY_C, true)
	_key(KEY_C, false)


## Horizontal movement since `start` points along `want` (ground plane).
func _moved_along(want: Vector3) -> bool:
	var moved: Vector3 = w.player.global_position - start
	return Vector2(moved.x, moved.z).normalized().dot(Vector2(want.x, want.z).normalized()) > 0.95


## Direction a ground-plane world vector `d` takes on the screen when the map (M) is drawn.
func _map_dir(d: Vector3) -> Vector2:
	var map: TextureRect = w.find_children("*", "TextureRect", true, false)[0]
	map.refresh()
	return map.get_global_transform().basis_xform(Vector2(d.x, d.z)).normalized()


func _physics_process(_delta: float) -> bool:
	frames += 1
	var p = w.player
	var V = p.View
	match frames:
		30:  # landed
			_press_c()
			assert(p.view == V.THIRD and p.tp_cam.current and p.avatar.visible and w.seasons.env.fog_enabled)
			start = p.global_position
			_key(KEY_W, true)
		45:
			_key(KEY_W, false)
			assert(_moved_along(-p.global_basis.z), "third person: W should go where the player faces")
			# The camera sits behind (along +Z of the player) and above the head.
			var back: Vector3 = p.tp_cam.global_position - p.global_position
			assert(back.dot(p.global_basis.z) > 1.0 and back.y > 1.0, "camera at %s" % back)
			assert(_map_dir(Vector3.FORWARD).is_equal_approx(Vector2.UP), "map: north up outside iso")
			var shadows: float = w.seasons.sun.directional_shadow_max_distance
			_press_c()
			assert(p.view == V.ISO and p.iso_cam.current and p.avatar.visible)
			assert(p.iso_cam.projection == Camera3D.PROJECTION_ORTHOGONAL)
			assert(not w.seasons.env.fog_enabled)
			assert(w.seasons.sun.directional_shadow_max_distance > shadows)
			# The player sits on the camera's view axis, so it is drawn in the middle of the screen.
			assert((p.global_position - p.iso_cam.global_position).normalized().is_equal_approx(-p.iso_cam.global_basis.z))
			start = p.global_position
			_key(KEY_W, true)
		75:
			_key(KEY_W, false)
			var away: Vector3 = -p.iso_cam.global_basis.z
			assert(_moved_along(away), "iso: W should go up the screen")
			assert((p.global_position - p.iso_cam.global_position).normalized().is_equal_approx(-p.iso_cam.global_basis.z))
			# The map turns with the iso camera: screen up/right are map up/right, and north (up-right on
			# screen, foreshortened by the camera pitch to ~30°) is up-right on the map too.
			var ahead: Vector3 = Vector3(away.x, 0, away.z)
			for d in [[ahead, 0.999], [p.iso_cam.global_basis.x, 0.999], [Vector3.FORWARD, 0.95]]:
				var on_screen: Vector2 = p.iso_cam.unproject_position(p.global_position + d[0]) - p.iso_cam.unproject_position(p.global_position)
				assert(_map_dir(d[0]).dot(on_screen.normalized()) > d[1], "iso map: %s goes %s on screen but %s on the map" % [d[0], on_screen, _map_dir(d[0])])
			_press_c()
			assert(p.view == V.FIRST and p.camera.current and not p.avatar.visible and w.seasons.env.fog_enabled)
			assert(w.seasons.sun.directional_shadow_max_distance < p.ISO_SHADOWS)
			print("VIEWS OK")
			quit()
	return false
