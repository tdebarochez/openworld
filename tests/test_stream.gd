extends SceneTree
# Run: godot --headless --path . -s tests/test_stream.gd
# Teleports the player 1 km away and checks the worker threads fill its view within a few seconds.

var w
var frames := 0
const FAR := Vector3(1000, 100, 0)


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 1:
		assert(w.threaded, "expected a threaded build")
		w.player.process_mode = Node.PROCESS_MODE_DISABLED  # keep it hovering at FAR
		w.player.global_position = FAR
	if frames == 2:
		assert(not w.jobs.is_empty(), "no worker jobs started")
	if frames > 2 and w.jobs.is_empty() and w.missing_cells_near(FAR).is_empty():
		print("STREAM OK: view filled in %d frames, %d zones" % [frames, w.zones.size()])
		quit()
	if frames == 600:
		assert(false, "view not filled after 600 frames")
		quit(1)
	return false
