extends SceneTree
# Run: godot --headless --path . -s tests/test_settings.gd
# O (density): a higher density keeps every object and adds more; loaded zones get rebuilt in place
# without dropping the player. P (view distance): fog end, camera far plane and streaming radius follow.

var w
var frames := 0
var trees_before := 0
var zones_before := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _tree_count() -> int:
	var n := 0
	for zone in w.zones.values():
		for c in zone.get_children():
			if c.has_meta("trees"):
				n += c.multimesh.instance_count
	return n


func _press(code: Key) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = true
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 30:
		# Pure placement: density 2 = density 1's trees plus more, same order.
		var cell := Vector2i(2, -1)
		var one: Array = w.tree_transforms(cell)
		w.density = 2.0
		var two: Array = w.tree_transforms(cell)
		w.density = 1.0
		for m in one.size():
			assert(two[m].slice(0, one[m].size()) == one[m], "density 2 moved existing trees")
		trees_before = _tree_count()
		zones_before = w.zones.size()
		_press(KEY_O)  # 1 → 1.5
		_press(KEY_O)  # → 2
		assert(w.density == 2.0)
		assert(w.stale.size() == w.zones.size())
		assert(w.hud.text.contains("×2"))
	elif frames > 30 and frames < 600 and w.stale.is_empty() and trees_before > 0 and w.view_dist == w.VIEW_DIST:
		var after := _tree_count()
		print("trees in loaded zones: %d at x1 -> %d at x2 (%d frames to rebuild)" % [trees_before, after, frames - 30])
		assert(after > trees_before * 1.6)
		assert(w.zones.size() == zones_before)
		assert(w.player.global_position.y > w.height(w.player.global_position.x, w.player.global_position.z) - 1.0, "player fell through")
		_press(KEY_P)  # 200 → 300 m
		assert(w.view_dist == 300.0)
		assert(w.seasons.env.fog_depth_end == 300.0)
		assert(w.player.camera.far == 350.0)
		assert(not w.missing_cells_near(w.player.global_position).is_empty())
	elif w.view_dist == 300.0 and w.jobs.is_empty() and w.missing_cells_near(w.player.global_position).is_empty():
		print("zones: %d at 200 m -> %d at 300 m" % [zones_before, w.zones.size()])
		assert(w.zones.size() > zones_before * 1.5)
		print("SETTINGS OK")
		quit()
	elif frames >= 1500:
		print("timeout: stale %d, view %d" % [w.stale.size(), w.view_dist])
		quit(1)
	return false
