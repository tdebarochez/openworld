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
		_check_map()
		quit()
	if frames == 600:
		assert(false, "view not filled after 600 frames")
		quit(1)
	return false


# Map around FAR: player's zone is a terrain tile, a zone 6 cells away is cloud (never generated).
# Saves the map to MAP_PNG (env var) when set, to look at it.
func _check_map() -> void:
	var map = w.find_children("", "TextureRect", true, false)[0]
	var t0 := Time.get_ticks_usec()
	map.refresh()
	print("map refresh ms: ", (Time.get_ticks_usec() - t0) / 1000.0)
	var img: Image = map.texture.get_image()
	var px: int = w.MAP_PX
	assert(img.get_size() == Vector2i.ONE * 13 * px)
	var centre_tile: Image = w.map_tiles[w.cell_of(FAR)]
	assert(img.get_pixel(6 * px + 1, 6 * px + 1).is_equal_approx(centre_tile.get_pixel(1, 1)))
	var cloud := img.get_pixel(px / 2, px / 2)  # top-left zone, 6 cells away: not generated
	assert(not w.zones.has(w.cell_of(FAR) - Vector2i(6, 6)))
	assert(cloud.r > 0.7 and cloud.b > cloud.g - 0.01, "expected cloud, got %s" % cloud)
	if OS.get_environment("MAP_PNG") != "":
		img.save_png(OS.get_environment("MAP_PNG"))
	print("MAP OK")
