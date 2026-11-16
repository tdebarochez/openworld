extends SceneTree
# Run: godot --headless --path . -s tests/test_birds.gd
# Tree birds spawn near the player, hop to a different tree, flee (chirping) when the player walks up
# to their tree and land well away from it; the flock stays above the player area.

const DT := 1.0 / 30.0


func _init() -> void:
	var w = preload("res://world.gd").new()
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			w.add_zone(Vector2i(dx, dz))
	var birds = preload("res://birds.gd").new()
	birds.world = w
	birds.setup()
	var pp := Vector3(0, w.height(0, 0) + 1.0, 0)

	# Spawn: some perched tree birds, all within range, capped.
	birds.simulate(DT, pp)
	var n: int = birds.tree_birds.size()
	print("tree birds: ", n, ", flock: ", birds.flock.size())
	assert(n > 0 and n <= birds.MAX_TREE_BIRDS)
	for b in birds.tree_birds:
		assert(b.state == birds.State.PERCHED)
		assert(birds._hdist(b.pos, pp) <= birds.SPAWN_RADIUS + 1.0)
	assert(birds.flock.size() == birds.FLOCK_SIZE)

	# Same world, same player spot -> same birds and tints.
	var again = preload("res://birds.gd").new()
	again.world = w
	again.setup()
	again.simulate(DT, pp)
	assert(again.tree_birds.size() == n)
	for i in n:
		assert(again.tree_birds[i].pos == birds.tree_birds[i].pos and again.tree_birds[i].tint == birds.tree_birds[i].tint)
	again.free()

	# Hop: picks another tree, flies, lands perched on it.
	var hopper = birds.tree_birds[0]
	var from: Vector3 = hopper.tree
	birds.hop(hopper, pp)
	assert(hopper.state == birds.State.FLYING and hopper.tree.distance_to(from) > 1.0)
	_run(birds, pp, hopper.dur + 0.1)
	assert(hopper.state == birds.State.PERCHED, "hopper did not land: state %d t %f" % [hopper.state, hopper.t])
	assert(hopper.pos.distance_to(hopper.tree) < 0.5)

	# Flee: the player walks to a perched bird's tree; it takes off with a call and lands far away.
	var target = null
	for b in birds.tree_birds:
		if b.state == birds.State.PERCHED:
			target = b
			break
	var near := Vector3(target.tree.x + 2.0, pp.y, target.tree.z)
	var calls: int = birds.chirps
	_run(birds, near, 0.6)
	assert(target.state == birds.State.FLYING, "bird did not flee")
	assert(birds.chirps > calls, "no call on take-off")
	_run(birds, near, 25.0)
	assert(target.state == birds.State.PERCHED, "fleeing bird never landed")
	assert(birds._hdist(target.pos, near) > birds.FLEE_RADIUS, "landed next to the player")
	for b in birds.tree_birds:  # nobody stays perched within the flee radius
		assert(b.state != birds.State.PERCHED or birds._hdist(b.pos, near) >= birds.FLEE_RADIUS)
	print("fled to ", target.tree, " (%.1f m from the player)" % birds._hdist(target.pos, near))

	# Flock: two minutes later still in the sky above the player area.
	_run(birds, pp, 120.0)
	for b in birds.flock:
		var above: float = b.pos.y - birds._ground(b.pos)
		assert(birds._hdist(b.pos, pp) < 150.0, "flock bird strayed %f m" % birds._hdist(b.pos, pp))
		assert(above > 7.0 and above < 80.0, "flock bird at %f m above ground" % above)
	print("flock centre %.1f m from the player" % birds._hdist(birds.flock[0].pos, pp))
	print("BIRDS OK")
	birds.free()
	w.free()
	quit()


func _run(birds, pp: Vector3, seconds: float) -> void:
	for i in int(seconds / DT):
		birds.simulate(DT, pp)
