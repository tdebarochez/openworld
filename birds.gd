extends Node3D
## Birds near the player: one flock of dusk birds wandering in the sky (boids), and azure / gold birds
## that perch on tree crowns, hop from tree to tree now and then, and flee when the player comes close.
## Everything is plain data simulated on the main thread (no threads, no particles: runs on the web
## export) and drawn as one MultiMesh per species; wings flap in the vertex shader.

const FLEE_RADIUS := 11.0  # perched birds take off when the player is closer (horizontal m)
const SPAWN_RADIUS := 80.0  # trees this close to the player may get birds (<= ZONE_SIZE, see trees_near)
const DESPAWN_RADIUS := 125.0  # perched birds farther away are dropped (> SPAWN_RADIUS + HOME_RANGE)
const MAX_TREE_BIRDS := 36
const NEST_CHANCE := 10  # % of trees that start with 1-3 birds
const HOP_INTERVAL := Vector2(8.0, 25.0)  # s perched before hopping to another tree
const HOP_RANGE := Vector2(5.0, 30.0)  # m to the next tree
const HOME_RANGE := 40.0  # random hops stay this close to the bird's nest tree
const FLEE_RANGE := Vector2(15.0, 50.0)  # m to the refuge tree
const HOP_SPEED := 6.0
const FLEE_SPEED := 11.0
const CHIRP_INTERVAL := Vector2(4.0, 15.0)  # s between chirps of a perched bird
const FLOCK_SIZE := 16
const FLOCK_HEIGHT := 30.0  # m above the ground
const FLOCK_ORBIT := 50.0  # the flock's goal circles the player this far out
const FLOCK_SPEED := Vector2(7.0, 13.0)
const FLOCK_CALL_INTERVAL := Vector2(5.0, 12.0)
const FLAP := [44.0, 60.0, 60.0]  # wing beat, rad/s, per species

enum Species { DUSK, AZURE, GOLD }  # DUSK flies in the flock; AZURE and GOLD live in trees
enum State { PERCHED, ALERT, FLYING }

# Per species (sRGB): back, belly/throat, head cap, wings, tail, beak; wing tip x (m); model scale.
const LOOKS := [
	[Color(0.22, 0.17, 0.14), Color(0.45, 0.36, 0.28), Color(0.1, 0.08, 0.08), Color(0.15, 0.12, 0.1),
		Color(0.17, 0.13, 0.11), Color(0.9, 0.7, 0.25), 0.2, 2.4],
	[Color(0.25, 0.45, 0.82), Color(0.9, 0.92, 0.95), Color(0.15, 0.3, 0.72), Color(0.14, 0.28, 0.65),
		Color(0.1, 0.2, 0.5), Color(0.2, 0.2, 0.22), 0.15, 1.6],
	[Color(0.95, 0.8, 0.15), Color(1.0, 0.9, 0.4), Color(0.95, 0.72, 0.1), Color(0.12, 0.11, 0.1),
		Color(0.14, 0.12, 0.1), Color(0.95, 0.55, 0.35), 0.15, 1.6],
]
const CALLS := [preload("res://assets/sounds/birds/dusk.wav"), preload("res://assets/sounds/birds/azure.wav"),
	preload("res://assets/sounds/birds/gold.wav")]
const SHADER := """
shader_type spatial;
render_mode cull_disabled;
// Wing vertices have UV.x = 1 and UV.y = hinge distance from the body axis. INSTANCE_CUSTOM =
// (phase, flap amplitude rad, flap speed rad/s, fold 0..1): folded wings lie back along the flanks.
void vertex() {
	if (UV.x > 0.5) {
		float side = sign(VERTEX.x);
		float d = abs(VERTEX.x) - UV.y;
		vec2 hinge = vec2(side * UV.y, VERTEX.y);
		vec2 r = vec2(side * d * mix(1.0, 0.08, INSTANCE_CUSTOM.w), 0.0);
		VERTEX.z += d * 0.45 * INSTANCE_CUSTOM.w;
		float a = side * (sin(TIME * INSTANCE_CUSTOM.z + INSTANCE_CUSTOM.x) * INSTANCE_CUSTOM.y
			- 0.3 * INSTANCE_CUSTOM.w);
		mat2 rot = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
		VERTEX.xy = hinge + rot * r;
		NORMAL.xy = rot * NORMAL.xy;
	}
}
void fragment() {
	ALBEDO = COLOR.rgb;  // vertex colour (body part) x instance colour (per-bird tint)
	ROUGHNESS = 0.9;
}
"""


class Bird:
	var species: int
	var tint: Color
	var rng := RandomNumberGenerator.new()
	var pos: Vector3  # feet when perched
	var vel: Vector3  # flock only
	var dir := Vector3.FORWARD  # heading while flying
	var yaw := 0.0  # heading while perched
	var state := State.PERCHED
	var timer := 0.0  # PERCHED: until next hop; ALERT: take-off delay
	var chirp := 0.0  # until next chirp
	var tree: Vector3  # crown top it perches on / flies to
	var to_tree := true  # false while escaping into the open sky
	var path: Array[Vector3] = []  # cubic Bezier control points of the current flight
	var t := 0.0  # flight progress 0..1
	var dur := 1.0  # flight duration, s
	var nest: Vector3i
	var phase := 0.0
	var amp := 0.0  # current flap amplitude
	var fold := 1.0


var world: Node3D  # world.gd; the parent unless set before setup()
var flock: Array[Bird] = []
var tree_birds: Array[Bird] = []
var nests := {}  # Vector3i (crown top, dm) -> birds still alive from it (0 = no birds / all gone)
var chirps := 0  # total calls so far (tests)
var time := 0.0
var _tops := {}  # Vector2i -> PackedVector3Array of world-space crown tops (zones never unload)
var _model_tops: Array[Vector3] = []  # per tree model, highest leaf vertex
var _mm: Array[MultiMesh] = []
var _voices: Array[AudioStreamPlayer3D] = []
var _manage_timer := 0.0
var _call_timer := 3.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	if world == null:
		world = get_parent()
	setup()


func setup() -> void:
	_rng.seed = 4242
	for m: ArrayMesh in world.species:
		var top := Vector3(0, -INF, 0)
		for v in m.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]:  # leaves surface
			if v.y > top.y:
				top = v
		_model_tops.append(top - Vector3(0, 0.05, 0))
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = SHADER
	for s in Species.size():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _bird_mesh(LOOKS[s])
		mm.instance_count = FLOCK_SIZE if s == Species.DUSK else MAX_TREE_BIRDS
		mm.visible_instance_count = 0
		mm.custom_aabb = AABB(Vector3.ONE * -1e5, Vector3.ONE * 2e5)  # no AABB rebuild per frame
		_mm.append(mm)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)
	for i in 6:  # shared pool: at most 6 calls at once
		var v := AudioStreamPlayer3D.new()
		_voices.append(v)
		add_child(v)


func _process(delta: float) -> void:
	if world.player:
		simulate(delta, world.player.global_position)
		_draw()


## One step of every bird, given the player position.
func simulate(delta: float, pp: Vector3) -> void:
	time += delta
	_manage_timer -= delta
	if _manage_timer <= 0.0:
		_manage_timer = 1.0
		_manage(pp)
	for b in tree_birds:
		_update_tree_bird(b, delta, pp)
	_update_flock(delta, pp)


## Crown tops within `r` (<= ZONE_SIZE) of `p`, horizontally.
func trees_near(p: Vector3, r: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var c: Vector2i = world.cell_of(p)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for top in _cell_tops(c + Vector2i(dx, dz)):
				if _hdist(top, p) <= r:
					out.append(top)
	return out


func _cell_tops(cell: Vector2i) -> PackedVector3Array:
	if not _tops.has(cell):
		if not world.zone_trees.has(cell):
			return PackedVector3Array()
		var origin := Vector3(cell.x, 0, cell.y) * float(world.ZONE_SIZE)
		var out := PackedVector3Array()
		var models: Array = world.zone_trees[cell]
		for m in models.size():
			for t: Transform3D in models[m]:
				out.append(origin + t * _model_tops[m])
		_tops[cell] = out
	return _tops[cell]


## Once a second: drop far perched birds, give birds to new nest trees around the player.
func _manage(pp: Vector3) -> void:
	for i in range(tree_birds.size() - 1, -1, -1):
		var b := tree_birds[i]
		if b.state == State.PERCHED and _hdist(b.pos, pp) > DESPAWN_RADIUS:
			nests[b.nest] -= 1
			tree_birds.remove_at(i)
	for key: Vector3i in nests.keys():
		if nests[key] <= 0 and _hdist(Vector3(key) / 10.0, pp) > DESPAWN_RADIUS:
			nests.erase(key)
	var tops := trees_near(pp, SPAWN_RADIUS)
	var order := Array(tops)
	order.sort_custom(func(a, b): return _hdist(a, pp) < _hdist(b, pp))
	for top: Vector3 in order:
		var key := Vector3i((top * 10.0).round())
		if nests.has(key):
			continue
		var h := hash(key)
		if h % 100 >= NEST_CHANCE:
			continue
		var n := 1 + (h >> 8) % 3
		if _hdist(top, pp) < FLEE_RADIUS or tree_birds.size() + n > MAX_TREE_BIRDS:
			nests[key] = 0  # never pop birds in under the player's nose; retried once out of range
			continue
		nests[key] = n
		for i in n:
			var b := Bird.new()
			b.species = Species.AZURE if (h >> 4) & 1 else Species.GOLD
			b.nest = key
			b.rng.seed = hash(Vector4i(key.x, key.y, key.z, i))
			_init_look(b)
			b.tree = top
			b.pos = _perch_spot(b, top)
			b.yaw = b.rng.randf() * TAU
			b.timer = b.rng.randf_range(HOP_INTERVAL.x, HOP_INTERVAL.y)
			b.chirp = b.rng.randf_range(0.5, CHIRP_INTERVAL.y)
			tree_birds.append(b)


func _update_tree_bird(b: Bird, delta: float, pp: Vector3) -> void:
	match b.state:
		State.PERCHED:
			if _hdist(b.pos, pp) < FLEE_RADIUS:
				b.state = State.ALERT
				b.timer = b.rng.randf_range(0.0, 0.4)  # birds of one tree leave one after the other
				return
			b.chirp -= delta
			if b.chirp <= 0.0:
				b.chirp = b.rng.randf_range(CHIRP_INTERVAL.x, CHIRP_INTERVAL.y)
				b.yaw += b.rng.randf_range(-1.5, 1.5)
				_call(b, pp)
			b.timer -= delta
			if b.timer <= 0.0:
				hop(b, pp)
		State.ALERT:
			b.timer -= delta
			if b.timer <= 0.0:
				flee(b, pp)
				_call(b, pp)
		State.FLYING:
			b.t = minf(b.t + delta / b.dur, 1.0)
			var s := b.t * b.t * (3.0 - 2.0 * b.t)  # slow take-off and landing
			b.pos = _bezier(b.path, s)
			var d := _bezier_tangent(b.path, s)
			if d.length_squared() > 1e-6:
				b.dir = d
			if b.t >= 1.0:
				if b.to_tree:
					b.state = State.PERCHED
					b.yaw = atan2(-b.dir.x, -b.dir.z)
					b.timer = b.rng.randf_range(HOP_INTERVAL.x, HOP_INTERVAL.y)
				else:
					hop(b, pp)  # came down from the open sky: land on a tree around here
	var flying := b.state == State.FLYING
	b.amp = move_toward(b.amp, 0.9 if flying else 0.0, delta * 6.0)
	b.fold = move_toward(b.fold, 0.0 if flying else 1.0, delta * 6.0)


## Fly to another tree nearby (not the current one, not close to the player), staying around the nest
## tree so a resting player's surroundings don't slowly empty.
func hop(b: Bird, pp: Vector3) -> void:
	var home := Vector3(b.nest) / 10.0
	var roam := maxf(HOME_RANGE, _hdist(b.pos, home))  # away from home (after fleeing): only come back
	var cands := PackedVector3Array()
	for top in trees_near(b.pos, HOP_RANGE.y):
		var d := _hdist(top, b.pos)
		if d >= HOP_RANGE.x and _hdist(top, pp) > FLEE_RADIUS * 1.5 and _hdist(top, home) <= roam:  # >= 5 m: never the same tree
			cands.append(top)
	if cands.is_empty() and not b.to_tree:  # in the sky with no tree in hop range: take any
		for top in trees_near(b.pos, world.ZONE_SIZE):
			if _hdist(top, pp) > FLEE_RADIUS * 1.5:
				cands.append(top)
	if cands.is_empty():
		b.timer = b.rng.randf_range(HOP_INTERVAL.x, HOP_INTERVAL.y)  # stay (or keep circling)
		if not b.to_tree:
			_fly(b, b.pos + Vector3(b.rng.randf_range(-20, 20), 0, b.rng.randf_range(-20, 20)), false, HOP_SPEED)
		return
	var top := cands[b.rng.randi() % cands.size()]
	b.tree = top
	_fly(b, _perch_spot(b, top), true, HOP_SPEED)


## Take off away from the player, to a tree well out of its reach, or up into the sky if there is none.
func flee(b: Bird, pp: Vector3) -> void:
	var away := Vector3(b.pos.x - pp.x, 0, b.pos.z - pp.z)
	away = away.normalized() if away.length_squared() > 0.01 else Vector3.FORWARD.rotated(Vector3.UP, b.rng.randf() * TAU)
	var cands := PackedVector3Array()
	for top in trees_near(b.pos, FLEE_RANGE.y):
		if _hdist(top, b.pos) >= FLEE_RANGE.x and _hdist(top, pp) > FLEE_RADIUS * 2.5 and (top - b.pos).dot(away) > 0.0:
			cands.append(top)
	if cands.is_empty():
		_fly(b, b.pos + away * 30.0 + Vector3.UP * 15.0, false, FLEE_SPEED)
		return
	var top := cands[b.rng.randi() % cands.size()]
	b.tree = top
	_fly(b, _perch_spot(b, top), true, FLEE_SPEED)


func _fly(b: Bird, target: Vector3, to_tree: bool, speed: float) -> void:
	var d := b.pos.distance_to(target)
	var lift := Vector3.UP * (1.5 + 0.2 * d)
	var fwd := (target - b.pos) * 0.25
	b.path = [b.pos, b.pos + lift + fwd, target + lift - fwd, target]
	b.dur = d * 1.3 / speed + 0.5
	b.t = 0.0
	b.to_tree = to_tree
	b.state = State.FLYING


func _perch_spot(b: Bird, top: Vector3) -> Vector3:
	return top + Vector3(b.rng.randf_range(-0.2, 0.2), b.rng.randf_range(-0.12, 0.0), b.rng.randf_range(-0.2, 0.2))


func _update_flock(delta: float, pp: Vector3) -> void:
	if flock.is_empty() or _hdist(flock[0].pos, pp) > 300.0:  # start, or the player teleported
		_spawn_flock(pp)
	var goal := flock_goal(pp)
	for b in flock:
		var sep := Vector3()
		var coh := Vector3()
		var ali := Vector3()
		var n := 0
		for o in flock:
			var off := b.pos - o.pos
			var d2 := off.length_squared()
			if o == b or d2 > 144.0:  # neighbours within 12 m
				continue
			n += 1
			coh += o.pos
			ali += o.vel
			if d2 < 16.0:  # keep ~4 m apart
				sep += off / maxf(d2, 0.01)
		var to_goal := goal - b.pos
		var acc := to_goal.normalized() * clampf(to_goal.length() / 20.0, 0.5, 4.0) + sep * 6.0
		if n > 0:
			acc += (coh / n - b.pos) * 0.15 + (ali / n - b.vel) * 0.5
		acc.y += (_ground(b.pos) + FLOCK_HEIGHT - b.pos.y) * 0.6 - b.vel.y * 0.5
		b.vel += acc * delta
		b.vel = b.vel.normalized() * clampf(b.vel.length(), FLOCK_SPEED.x, FLOCK_SPEED.y)
		b.pos += b.vel * delta
		b.pos.y = maxf(b.pos.y, _ground(b.pos) + 8.0)
		b.dir = b.vel
		# Flap, glide now and then; always flap when climbing.
		var flap := sin(time * 0.7 + b.phase) > -0.2 or b.vel.y > 1.0
		b.amp = move_toward(b.amp, 0.9 if flap else 0.12, delta * 3.0)
	_call_timer -= delta
	if _call_timer <= 0.0:
		_call_timer = _rng.randf_range(FLOCK_CALL_INTERVAL.x, FLOCK_CALL_INTERVAL.y)
		_call(flock[_rng.randi() % flock.size()], pp)


## Where the flock heads: a point slowly circling the player, its radius breathing between 30 and 70 m.
func flock_goal(pp: Vector3) -> Vector3:
	var r := FLOCK_ORBIT + 20.0 * sin(time * 0.017)
	var g := pp + Vector3(cos(time * 0.04), 0, sin(time * 0.04)) * r
	g.y = _ground(g) + FLOCK_HEIGHT
	return g


func _spawn_flock(pp: Vector3) -> void:
	flock.clear()
	var g := flock_goal(pp)
	for i in FLOCK_SIZE:
		var b := Bird.new()
		b.species = Species.DUSK
		b.rng.seed = hash(Vector2i(4242, i))
		_init_look(b)
		b.pos = g + Vector3(b.rng.randf_range(-8, 8), b.rng.randf_range(-3, 3), b.rng.randf_range(-8, 8))
		b.vel = Vector3(1, 0, 0.3).normalized() * FLOCK_SPEED.x
		b.state = State.FLYING
		b.fold = 0.0
		flock.append(b)


## Per-bird tint (brightness +-15 %, warmer or cooler) and wing-beat phase, from the bird's own RNG.
func _init_look(b: Bird) -> void:
	var k := b.rng.randf_range(0.85, 1.15)
	var w := b.rng.randf_range(-0.07, 0.07)
	b.tint = Color(k * (1.0 + w), k, k * (1.0 - w))
	b.phase = b.rng.randf() * TAU


func _call(b: Bird, pp: Vector3) -> void:
	if world.seasons.season == world.seasons.Season.WINTER:
		return  # birds keep quiet in winter
	chirps += 1
	var flocked := b.species == Species.DUSK
	if not is_inside_tree() or b.pos.distance_to(pp) > (160.0 if flocked else 60.0):
		return
	for v in _voices:
		if not v.playing:
			v.stream = CALLS[b.species]
			v.position = b.pos  # this node sits at the world origin
			v.pitch_scale = b.rng.randf_range(0.9, 1.1)
			v.unit_size = 15.0 if flocked else 4.0
			v.max_distance = 160.0 if flocked else 60.0
			v.volume_db = -4.0
			v.play()
			return


func _draw() -> void:
	var counts := [0, 0, 0]
	for b in flock + tree_birds:
		var i: int = counts[b.species]
		counts[b.species] = i + 1
		var mm := _mm[b.species]
		var basis := Basis(Vector3.UP, b.yaw) if b.state != State.FLYING else _facing(b.dir)
		mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3.ONE * LOOKS[b.species][7]), b.pos))
		mm.set_instance_color(i, b.tint)
		mm.set_instance_custom_data(i, Color(b.phase, b.amp, FLAP[b.species], b.fold))
	for s in Species.size():
		_mm[s].visible_instance_count = counts[s]


## Heading along `d`, pitch limited to ~55 deg so steep climbs and drops never flip the bird.
func _facing(d: Vector3) -> Basis:
	var hz := Vector2(d.x, d.z).length()
	if hz < 1e-3:
		return Basis()
	var f := Vector3(d.x, clampf(d.y, -1.4 * hz, 1.4 * hz), d.z)
	return Basis.looking_at(f, Vector3.UP)


func _ground(p: Vector3) -> float:
	return maxf(world.height(p.x, p.z), world.WATER_LEVEL)


static func _hdist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func _bezier(p: Array[Vector3], s: float) -> Vector3:
	var u := 1.0 - s
	return p[0] * u * u * u + p[1] * 3.0 * u * u * s + p[2] * 3.0 * u * s * s + p[3] * s * s * s


static func _bezier_tangent(p: Array[Vector3], s: float) -> Vector3:
	var u := 1.0 - s
	return (p[1] - p[0]) * 3.0 * u * u + (p[2] - p[1]) * 6.0 * u * s + (p[3] - p[2]) * 3.0 * s * s


## ~44-triangle low-poly bird, flat shaded, origin at the feet, beak towards -Z. Body parts are vertex
## colours (multiplied by the instance tint in the shader); wing vertices are tagged in UV for flapping.
static func _bird_mesh(look: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tri := func(a: Vector3, b: Vector3, c: Vector3, col: Color, inside: Vector3, uv := Vector2.ZERO) -> void:
		var n := (b - a).cross(c - a).normalized()
		var order := [a, c, b]  # Godot's front faces wind clockwise
		if n.dot((a + b + c) / 3.0 - inside) < 0.0:
			n = -n
			order = [a, b, c]
		st.set_normal(n)
		st.set_color(col.srgb_to_linear())
		st.set_uv(uv)
		for v: Vector3 in order:
			st.add_vertex(v)
	var back: Color = look[0]
	var belly: Color = look[1]
	var cy := 0.045  # body axis height
	var centre := Vector3(0, cy, 0)
	# Body: nose, two hexagonal rings, tail point.
	var nose := Vector3(0, cy + 0.01, -0.07)
	var tail := Vector3(0, cy + 0.01, 0.075)
	var r1: Array[Vector3] = []
	var r2: Array[Vector3] = []
	for k in 6:
		var a := k * TAU / 6.0
		r1.append(Vector3(0.034 * cos(a), cy + 0.032 * sin(a), -0.025))
		r2.append(Vector3(0.026 * cos(a), cy + 0.005 + 0.026 * sin(a), 0.035))
	for k in 6:
		var j := (k + 1) % 6
		var col := back if k < 3 else belly  # ring angles 0..180 deg are the upper half
		tri.call(nose, r1[k], r1[j], col, centre)
		tri.call(r1[k], r2[k], r2[j], col, centre)
		tri.call(r1[k], r2[j], r1[j], col, centre)
		tri.call(r2[k], tail, r2[j], col, centre)
	# Head: octahedron, cap on top, throat below.
	var hc := Vector3(0, cy + 0.04, -0.06)
	var hr := 0.027
	var ring: Array[Vector3] = [hc + Vector3(hr, 0, 0), hc + Vector3(0, 0, -hr), hc + Vector3(-hr, 0, 0), hc + Vector3(0, 0, hr)]
	for k in 4:
		tri.call(hc + Vector3(0, hr, 0), ring[k], ring[(k + 1) % 4], look[2], hc)
		tri.call(hc - Vector3(0, hr, 0), ring[k], ring[(k + 1) % 4], belly, hc)
	# Beak: four-sided pyramid.
	var bc := hc + Vector3(0, -0.003, -0.022)
	var tip := hc + Vector3(0, -0.006, -0.05)
	var sq: Array[Vector3] = [bc + Vector3(0.008, 0, 0), bc + Vector3(0, 0.008, 0), bc + Vector3(-0.008, 0, 0), bc + Vector3(0, -0.008, 0)]
	for k in 4:
		tri.call(tip, sq[k], sq[(k + 1) % 4], look[5], bc)
	# Tail fan.
	var below := Vector3(0, cy - 0.1, 0.1)
	var t0 := Vector3(0.012, cy + 0.012, 0.06)
	var t1 := Vector3(0.032, cy + 0.02, 0.135)
	var mx := Vector3(-1, 1, 1)
	tri.call(t0, t1, t1 * mx, look[4], below)
	tri.call(t0, t1 * mx, t0 * mx, look[4], below)
	# Wings: swept, three triangles each, darker tip. Hinge along x = 0.028.
	var span: float = look[6]
	var wy := cy + 0.025
	var wing: Color = look[3]
	for s in [1.0, -1.0]:
		var rf := Vector3(s * 0.028, wy, -0.025)
		var rb := Vector3(s * 0.028, wy, 0.03)
		var mf := Vector3(s * span * 0.55, wy, -0.02)
		var mb := Vector3(s * span * 0.5, wy, 0.05)
		var wt := Vector3(s * span, wy, 0.045 + span * 0.25)
		var under := Vector3(s * span * 0.5, wy - 1.0, 0)
		var uv := Vector2(1.0, 0.028)
		tri.call(rf, rb, mb, wing, under, uv)
		tri.call(rf, mb, mf, wing, under, uv)
		tri.call(mf, mb, wt, wing * 0.7, under, uv)
	return st.commit()
