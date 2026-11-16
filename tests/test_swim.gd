extends SceneTree
# Run: godot --headless --path . -s tests/test_swim.gd
# Drops the player into a deep lake and checks it ends up floating at the surface.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _drop_in_lake() -> void:  # after world _ready, which creates the player
	for x in range(-1000, 1000, 8):
		for z in range(-1000, 1000, 8):
			if w.height(x, z) < -5.0:
				var spot := Vector3(x, 3, z)
				w.add_zone(w.cell_of(spot))  # ground under the player before it falls
				w.player.position = spot
				print("lake spot ", x, ",", z)
				return
	push_error("no deep lake within 1 km")
	quit(1)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		_drop_in_lake()
	if frames == 400:
		var y: float = w.player.global_position.y
		assert(absf(y - (w.WATER_LEVEL - 0.3)) < 0.15, "not floating, y=%f" % y)
		print("SWIM OK y=", y)
		quit()
	return false
