extends SceneTree
# Run: godot --headless --path . -s tests/test_hen.gd
# The player's hen (assets/hen/hen.glb): five looping animations, feet at the bottom of the collision
# capsule, 1.7-2 m tall, beak towards -Z, palette colours; play() cross-fades without restarting, and
# player._animate() picks idle/walk/run on the ground, flap rising and glide falling.

var w
var frames := 0


func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	root.add_child(w)


func _physics_process(_delta: float) -> bool:
	frames += 1
	if frames == 30:  # landed
		if _check():
			print("HEN OK")
			quit()
		else:
			quit(1)
	return false


func _check():
	var p = w.player
	var hen: Node3D = p.avatar
	var ap: AnimationPlayer = hen.anim
	for n in ["idle", "walk", "run", "flap", "glide"]:
		assert(ap.has_animation(n), "no %s animation" % n)
		assert(ap.get_animation(n).loop_mode == Animation.LOOP_LINEAR, "%s doesn't loop" % n)
	assert(ap.get_animation_list().size() == 5)

	# Shape, in the player's frame (rest pose): feet on the capsule bottom, height, beak in front.
	var mi: MeshInstance3D = hen.find_children("", "MeshInstance3D")[0]
	var to_player: Transform3D = p.global_transform.affine_inverse() * mi.global_transform
	var box: AABB = to_player * mi.get_aabb()
	var cap: CapsuleShape3D = p.find_children("", "CollisionShape3D", false, false)[0].shape
	print("hen box %s, %d bones" % [box, mi.get_parent().get_bone_count()])
	assert(absf(box.position.y + cap.height / 2) < 0.03, "feet off the capsule bottom")
	assert(box.size.y > 1.7 and box.size.y < 2.0, "height")
	# One white surface, every vertex colour a palette colour × the baked shading.
	assert(mi.mesh.get_surface_count() == 1 and mi.mesh.surface_get_material(0).albedo_color == Color.WHITE)
	var arrays := mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var paint := ["feather", "cream", "comb", "beak", "ink"].map(w.seasons.colour)
	var used := {}
	var beak := 0
	for i in verts.size():
		var k := -1
		for j in paint.size():
			var c: Color = paint[j] * (cols[i].g / paint[j].g)  # shade = the green ratio
			if cols[i].g / paint[j].g > 0.3 and absf(c.r - cols[i].r) < 0.012 and absf(c.b - cols[i].b) < 0.012:
				k = j
		assert(k >= 0, "vertex colour %s is no palette colour" % cols[i])
		used[k] = true
		if k == 3 and verts[i].y > 1.2:  # the beak, not the legs
			beak += 1
			assert((to_player * verts[i]).z < -0.4, "beak not at -Z")
	assert(used.size() == paint.size() and beak >= 4)
	assert(mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

	# play(): switches, sets the speed, ignores unknown names, doesn't restart the current one.
	hen.play(&"walk", 1.5)
	assert(ap.current_animation == "walk" and ap.speed_scale == 1.5)
	ap.seek(0.05, true)
	hen.play(&"walk")
	assert(ap.current_animation == "walk" and absf(ap.current_animation_position - 0.05) < 0.001, "restarted")
	assert(ap.speed_scale == 1.0)
	hen.play(&"nope", 3.0)
	assert(ap.current_animation == "walk" and ap.speed_scale == 1.0)

	# _animate() from move_state (player.gd sets it each physics frame; set here by hand) and the velocity.
	assert(p.is_on_floor())
	for c in [[Vector3.ZERO, &"idle", "idle"], [Vector3(p.SPEED, 0, 0), &"walk", "walk"],
			[Vector3(0, 0, p.SPEED * p.SPRINT_MULT), &"run", "run"], [Vector3.ZERO, &"swim", "idle"]]:
		p.velocity = c[0]
		p.move_state = c[1]
		p._animate()
		assert(ap.current_animation == c[2], "%s at %s: %s" % [c[1], c[0], ap.current_animation])
	assert(is_equal_approx(ap.speed_scale, 1.0))
	# Top of a jump (slow fall) keeps the flap; a fast fall or a glide spreads the wings.
	for c in [[Vector3(0, 5, 0), &"flap", "flap"], [Vector3(0, 0.2, 0), &"fall", "flap"],
			[Vector3(0, -5, 0), &"fall", "glide"], [Vector3(0, 5, 0), &"flap", "flap"], [Vector3(0, -2, 0), &"glide", "glide"]]:
		p.velocity = c[0]
		p.move_state = c[1]
		p._animate()
		assert(ap.current_animation == c[2], "%s at %s: %s" % [c[1], c[0], ap.current_animation])
	return true
