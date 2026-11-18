extends Node3D
## The player's hen: root script of assets/hen/hen.glb (set in its .import; the model comes from
## tools/make_hen.py). Animations idle, walk (made for 8 m/s), run (20 m/s), flap (take-off), glide
## and swim (floating, paddling), all looping.

const BLEND := 0.15  # s of cross-fade between two animations

@onready var anim: AnimationPlayer = $AnimationPlayer


func _ready() -> void:
	for mi: MeshInstance3D in find_children("", "MeshInstance3D"):
		for s in mi.mesh.get_surface_count():  # white: the colours are painted in (sRGB vertex colours)
			var mat := mi.mesh.surface_get_material(s) as StandardMaterial3D
			mat.vertex_color_use_as_albedo = true
			mat.vertex_color_is_srgb = true
	anim.play(&"idle")


## Cross-fade to animation `state` (unknown names are ignored, the current one isn't restarted),
## played at `speed_scale` (ground speed / the speed walk or run was made for).
func play(state: StringName, speed_scale := 1.0) -> void:
	if not anim.has_animation(state):
		return
	anim.speed_scale = speed_scale
	if anim.current_animation != state:
		anim.play(state, BLEND)
