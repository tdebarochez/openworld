"""Generate the player's hen: a low-poly mesh skinned to a 14-bone armature, with its animations.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_hen.py
Then: godot --headless --path . --import

Writes assets/hen/hen.glb. Feet at the origin (player.gd puts it at the bottom of the collision
capsule), beak towards Blender +Y = Godot -Z, about 1.8 m to the top of the comb. Rest pose: wings
spread flat (so the baked shading isn't darkened by the body); the animations fold them.
One surface with a white material: vertex colour COLOR_0 = palette colour (feather; cream on the wings
and tail; comb on the comb and wattle; beak on the beak and legs; ink eyes) × the baked shading
(tools/make_trees.py bake_shade), read as sRGB by hen.gd. One surface because the Compatibility
renderer (web) skins every surface in its own pass: 5 surfaces cost ~4 ms a frame on an M1, 1 ~1.8 ms.
Animations, keyed on every frame at 60 fps, all looping (the "-loop" suffix tells Godot's importer):
  idle   2.5 s, breathing, the head looks left then right
  walk   matched to 8 m/s: 0.15 s stride cycle, feet planted (no skating) for half of it
  run    matched to 20 m/s (Shift): body leaning forward, wings half out, feet planted for 30 %
  flap   two strong wing beats in 0.5 s, body tilted up, legs dangling: the take-off
  glide  2 s, wings spread and still but for a little feather wobble, legs tucked
  swim   1.2 s, body raised to float in the water, gentle bob and sway, legs paddling in turn
Legs on the ground are posed by a two-bone IK in the side plane, so the feet stay put while the body moves.
Everything is computed (no random), so re-running gives the same file.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_trees import PALETTE, bake_shade, tube  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "hen")
FPS = 60
FEATHER, WING, COMB, BEAK, EYE = range(5)
D = math.pi / 180
# Blender axes: +Y = front (Godot -Z), Z up, feet on z = 0. s = +1 for the hen's right side (+X), -1 left.
SIDES = ((1, "r"), (-1, "l"))
PIVOT = Vector((0, 0, 0.80))  # body bone: the hips sit next to it, so tilting the body keeps them in place
HIP, KNEE, ANKLE = (0.17, 0.0, 0.78), (0.18, 0.10, 0.42), (0.18, 0.0, 0.075)
SHOULDER, WRIST, TIP = (0.36, 0.14, 1.06), (0.76, 0.14, 1.06), (1.16, 0.0, 1.06)


def xs(p, s):
    return Vector((p[0] * s, p[1], p[2]))


BONES = [("body", PIVOT, PIVOT + Vector((0, 0.3, 0)), None),
         ("neck", (0, 0.20, 1.08), (0, 0.30, 1.36), "body"),
         ("head", (0, 0.30, 1.36), (0, 0.34, 1.64), "neck"),
         ("tail", (0, -0.40, 1.02), (0, -0.58, 1.32), "body")]
for _s, _n in SIDES:
    BONES += [(f"wing_{_n}", xs(SHOULDER, _s), xs(WRIST, _s), "body"),
              (f"hand_{_n}", xs(WRIST, _s), xs(TIP, _s), f"wing_{_n}"),
              (f"thigh_{_n}", xs(HIP, _s), xs(KNEE, _s), "body"),
              (f"shin_{_n}", xs(KNEE, _s), xs(ANKLE, _s), f"thigh_{_n}"),
              (f"foot_{_n}", xs(ANKLE, _s), xs((0.18, 0.2, 0.03), _s), f"shin_{_n}")]
GROUP = {b[0]: i for i, b in enumerate(BONES)}


# --- Mesh ---------------------------------------------------------------------------------------

def skin(bm, verts, weights):
    """weights: {bone: w} for all `verts`, or a function vert -> {bone: w}."""
    dl = bm.verts.layers.deform.verify()
    for v in verts:
        for b, w in (weights(v) if callable(weights) else weights).items():
            if w > 0:
                v[dl][GROUP[b]] = w


def faces_of(verts):
    return {f for v in verts for f in v.link_faces}


def blob(bm, c, r, bone, mat=FEATHER, segs=10, rings=6, basis=Matrix.Identity(3), smooth=True):
    """Low-poly ellipsoid at `c`, half-extents `r` along the columns of `basis`."""
    m = Matrix.Translation(c) @ basis.to_4x4() @ Matrix.Diagonal((*r, 1))
    verts = bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0, matrix=m)["verts"]
    for f in faces_of(verts):
        f.material_index = mat
        f.smooth = smooth
    skin(bm, verts, {bone: 1.0})
    return verts


def on(c, r, d):
    """Point of ellipsoid (c, r) in direction d."""
    d = Vector(d).normalized()
    return Vector(c) + Vector((d.x * r[0], d.y * r[1], d.z * r[2]))


def facing(d, side=Vector((1, 0, 0))):
    """Basis with Z along d and X as close to `side` as possible."""
    z = Vector(d).normalized()
    x = (side - z * side.dot(z)).normalized()
    return Matrix((x, z.cross(x), z)).transposed()


def piped(bm, path, radii, sides, bone, mat):
    before = set(bm.verts)
    tube(bm, [Vector(p) for p in path], radii, sides, bumpy=0.0)
    verts = set(bm.verts) - before
    for f in faces_of(verts):
        f.material_index = mat
    skin(bm, verts, {bone: 1.0})


# Wing outline seen from above, right wing (x > 0): leading edge out to the tip, then back along the
# trailing edge's scalloped primaries to the root, which is buried in the body's side.
WING_OUTLINE = [(0.30, 0.22), (0.55, 0.27), (0.80, 0.24), (1.02, 0.14), (1.17, -0.01),
                (1.13, -0.13), (1.01, -0.08), (0.99, -0.25), (0.87, -0.16), (0.83, -0.33), (0.71, -0.22),
                (0.65, -0.35), (0.53, -0.24), (0.47, -0.33), (0.30, -0.22)]


def wing(bm, s, n):
    """Flat feathered wing in its spread rest pose, thicker at the root; the hand bone takes the outer half."""
    top, bot = [], []
    for x, y in WING_OUTLINE:
        th = 0.05 * (1 - 0.6 * (x - 0.3) / 0.87)
        top.append(bm.verts.new((x * s, y, SHOULDER[2] + th)))
        bot.append(bm.verts.new((x * s, y, SHOULDER[2] - th)))
    k = len(top)
    faces = [bm.faces.new(top), bm.faces.new(bot[::-1])]
    faces += [bm.faces.new((top[i], bot[i], bot[(i + 1) % k], top[(i + 1) % k])) for i in range(k)]
    for f in faces:
        f.material_index = WING
        f.smooth = False

    def w(v):
        h = min(max((abs(v.co.x) - WRIST[0] + 0.07) / 0.14, 0.0), 1.0)
        h = h * h * (3 - 2 * h)
        return {f"wing_{n}": 1 - h, f"hand_{n}": h}
    skin(bm, top + bot, w)


def build_mesh():
    bm = bmesh.new()
    bm.verts.layers.deform.verify()  # before any vertex: adding a layer invalidates them
    # Body: an egg whose rear rises towards the tail.
    body = blob(bm, (0, -0.04, 0.84), (0.42, 0.52, 0.42), "body", segs=14, rings=9)
    for v in body:
        v.co.z += 0.16 * max(-(v.co.y + 0.04) / 0.52, 0) ** 2
    blob(bm, (0, 0.25, 1.20), (0.22, 0.21, 0.27), "neck", segs=10, rings=6)
    hc, hr = Vector((0, 0.36, 1.50)), (0.2, 0.22, 0.2)
    blob(bm, hc, hr, "head", segs=12, rings=8)
    for c, r in (((0, 0.45, 1.70), (0.035, 0.055, 0.055)), ((0, 0.36, 1.745), (0.04, 0.07, 0.07)),
                 ((0, 0.26, 1.715), (0.035, 0.06, 0.06))):
        blob(bm, c, r, "head", COMB, 8, 5)
    blob(bm, (0, 0.50, 1.32), (0.04, 0.045, 0.075), "head", COMB, 8, 5)
    d = Vector((0, 1, -0.25)).normalized()
    beak = bmesh.ops.create_cone(bm, cap_ends=True, segments=4, radius1=0.065, radius2=0.0, depth=0.16,
                                 matrix=Matrix.Translation(Vector((0, 0.53, 1.475)) + d * 0.08) @ facing(d).to_4x4())
    for f in faces_of(beak["verts"]):
        f.material_index = BEAK
        f.smooth = False
    skin(bm, beak["verts"], {"head": 1.0})
    for s, _ in SIDES:
        blob(bm, on(hc, hr, (0.62 * s, 0.72, 0.28)), (0.042, 0.042, 0.048), "head", EYE, 8, 5)
    # Tail: a fan of five feathers.
    for a in (-2, -1, 0, 1, 2):
        d = Vector((a * 0.17, -0.55, 0.85 - 0.06 * abs(a)))
        length = 0.38 - 0.035 * abs(a)
        blob(bm, Vector((a * 0.03, -0.40, 1.04)) + d.normalized() * length * 0.5, (0.10, 0.035, length * 0.5),
             "tail", WING, 8, 5, facing(d))
    for s, n in SIDES:
        wing(bm, s, n)
        blob(bm, xs((0.18, 0.06, 0.50), s), (0.12, 0.14, 0.13), f"thigh_{n}", segs=8, rings=5)  # feathered thigh
        a = xs(ANKLE, s)
        piped(bm, [xs(KNEE, s) + Vector((0, 0, 0.04)), a], [0.042, 0.036], 6, f"shin_{n}", BEAK)
        blob(bm, a, (0.045, 0.045, 0.045), f"foot_{n}", BEAK, 6, 4)
        for yaw, length in ((-0.5, 0.2), (0.0, 0.22), (0.5, 0.2), (math.pi, 0.09)):
            dirn = Vector((math.sin(yaw) * s, math.cos(yaw), 0))
            piped(bm, [a, a + dirn * length * 0.5 + Vector((0, 0, -0.03)), a + dirn * length + Vector((0, 0, -0.045))],
                  [0.032, 0.026, 0.018], 5, f"foot_{n}", BEAK)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Same triangulate-and-sort as make_trees.build, so the file comes out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    bake_shade(bm, 0.25, strength=0.45, base=0.85)
    col = bm.loops.layers.float_color["Col"]
    paint = [[int(PALETTE[c][i:i + 2], 16) / 255 for i in (1, 3, 5)] for c in ("feather", "cream", "comb", "beak", "ink")]
    for f in bm.faces:
        for loop in f.loops:
            loop[col] = (*(loop[col][0] * c for c in paint[f.material_index]), 1.0)
        f.material_index = 0
    mesh = bpy.data.meshes.new("hen")
    bm.to_mesh(mesh)
    print(f"hen: {len(bm.faces)} triangles, {len(BONES)} bones, "
          f"{min(v.co.z for v in bm.verts):.3f} to {max(v.co.z for v in bm.verts):.2f} m, "
          f"beak tip y {max(v.co.y for v in bm.verts):.2f}")
    bm.free()
    mat = bpy.data.materials.new("hen")
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (1, 1, 1, 1)
    bsdf.inputs["Roughness"].default_value = 0.9
    mesh.materials.append(mat)
    return mesh


# --- Poses --------------------------------------------------------------------------------------
# A pose is {bone: rotation} (3x3, about the bone's head, in armature axes as if its parent were at
# rest) plus the body's translation; keys() converts to Blender's bone-local quaternions.

def rx(a):
    return Matrix.Rotation(a, 3, "X")  # + = front up


def ry(a):
    return Matrix.Rotation(a, 3, "Y")  # + = right side down


def rz(a):
    return Matrix.Rotation(a, 3, "Z")  # + = turn left


def fold(s):
    """Wing folded against the body's side: rolled so the leading edge is on top and the trailing edge
    flares out over the body, swung back, tip a little down."""
    return rx(12 * D) @ rz(-s * 90 * D) @ rx(100 * D)


def spread(s, elev, sweep=0.0):
    """Wing out to the side, raised `elev` above flat, swept back `sweep`."""
    return rz(-s * sweep) @ ry(-s * elev)


def mix(a, b, t):
    return a.to_quaternion().slerp(b.to_quaternion(), t).to_matrix()


def ang(v):
    return math.atan2(v.z, v.y)


def leg(pose, s, n, body_r, body_t, foot_y, lift, toe):
    """Two-bone IK in the side plane: ankle to (foot_y, ANKLE z + lift) from the posed hip, knee forward,
    foot pitched `toe` (0 = flat on the ground)."""
    hip, knee, ankle = Vector(HIP), Vector(KNEE), Vector(ANKLE)
    l1, l2 = (knee - hip).length, (ankle - knee).length
    h = PIVOT + body_t + body_r @ (hip - PIVOT)
    t = Vector((0, foot_y, ANKLE[2] + lift))
    v = t - h
    v.x = 0
    dist = min(max(v.length, abs(l1 - l2) + 1e-4), l1 + l2 - 1e-4)
    a1 = ang(v) + math.acos((l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist))
    k = h + Vector((0, math.cos(a1), math.sin(a1))) * l1
    th = a1 - ang(knee - hip)
    sh = ang(t - k) - ang(ankle - knee)
    pose[f"thigh_{n}"] = body_r.inverted() @ rx(th)
    pose[f"shin_{n}"] = rx(sh - th)
    pose[f"foot_{n}"] = rx(toe - sh)


def gait(pose, p, body_r, body_t, stride, duty, height):
    """Feet planted for `duty` of the cycle, sliding back `stride` m at the body's speed, then swung forward."""
    for s, n in SIDES:
        ph = (p + (0.0 if s > 0 else 0.5)) % 1.0
        if ph < duty:
            y, lift, toe = stride * (0.5 - ph / duty), 0.0, 0.0
        else:
            u = (ph - duty) / (1 - duty)
            y = stride * (0.5 * (1 - math.cos(math.pi * u)) - 0.5)
            lift, toe = height * math.sin(math.pi * u), -0.7 * math.sin(math.pi * u)
        leg(pose, s, n, body_r, body_t, ANKLE[1] + 0.02 + y, lift, toe)


def body(pose, pitch=0.0, roll=0.0, yaw=0.0, z=0.0):
    r = rz(yaw) @ ry(roll) @ rx(pitch)
    pose["body"] = r
    return r, Vector((0, 0, z))


def idle(p):
    pose = {}
    w = 2 * math.pi * p
    r, t = body(pose, pitch=1.5 * D * math.sin(2 * w), z=-0.008 + 0.008 * math.cos(2 * w))
    look = math.tanh(5 * math.sin(w)) / math.tanh(5)  # snaps left, holds, snaps right
    pose["neck"] = rx(4 * D * math.sin(2 * w + 1)) @ rz(10 * D * look)
    pose["head"] = rz(18 * D * look) @ ry(-10 * D * math.tanh(5 * math.sin(w + 0.4)) / math.tanh(5))
    pose["tail"] = rz(5 * D * math.sin(w))
    for s, n in SIDES:
        pose[f"wing_{n}"] = ry(-s * 2 * D * (1 + math.sin(2 * w))) @ fold(s)
        leg(pose, s, n, r, t, ANKLE[1] + 0.02 * s, 0.0, 0.0)
    return pose, t


def walk(p):
    pose = {}
    w = 2 * math.pi * p
    r, t = body(pose, pitch=-8 * D + 2 * D * math.cos(2 * w), roll=4 * D * math.sin(w),
                z=-0.03 + 0.025 * math.cos(2 * w))
    pose["neck"] = rx(-8 * D + 6 * D * math.sin(2 * w + 1))
    pose["head"] = rx(8 * D - 5 * D * math.sin(2 * w + 1))
    pose["tail"] = rz(6 * D * math.sin(w)) @ rx(4 * D * math.cos(2 * w))
    for s, n in SIDES:
        pose[f"wing_{n}"] = ry(-s * 4 * D * (1 + math.sin(2 * w))) @ fold(s)
    gait(pose, p, r, t, 0.6, 0.5, 0.10)
    return pose, t


def run(p):
    pose = {}
    w = 2 * math.pi * p
    r, t = body(pose, pitch=-22 * D, roll=3 * D * math.sin(w), z=-0.10 + 0.04 * math.cos(2 * w))
    pose["neck"] = rx(-28 * D + 4 * D * math.sin(2 * w))
    pose["head"] = rx(30 * D - 4 * D * math.sin(2 * w))
    pose["tail"] = rx(12 * D) @ rz(5 * D * math.sin(w))
    for s, n in SIDES:
        pose[f"wing_{n}"] = ry(-s * 12 * D * math.sin(2 * w)) @ mix(fold(s), spread(s, 10 * D, 30 * D), 0.4)
    gait(pose, p, r, t, 0.8, 0.3, 0.18)
    return pose, t


def flap(p):
    pose = {}
    w = 4 * math.pi * p  # two beats
    body(pose, pitch=25 * D + 4 * D * math.cos(w), z=-0.04 * math.cos(w))  # rises on the downstroke
    pose["neck"] = rx(-18 * D)
    pose["head"] = rx(-8 * D)
    pose["tail"] = rx(-15 * D + 6 * D * math.cos(w))
    up = max(0.0, -math.sin(w))  # upstroke: sweep the wing back and fold the hand
    for s, n in SIDES:
        pose[f"wing_{n}"] = spread(s, 20 * D + 60 * D * math.cos(w), 20 * D * up)
        pose[f"hand_{n}"] = spread(s, 25 * D * math.cos(w - 0.9), 35 * D * max(0.0, -math.sin(w - 0.5)))
        pose[f"thigh_{n}"] = rx(-45 * D + 8 * D * math.sin(w + s))
        pose[f"shin_{n}"] = rx(-20 * D)
        pose[f"foot_{n}"] = rx(-40 * D)
    return pose, Vector((0, 0, -0.04 * math.cos(w)))


def glide(p):
    pose = {}
    w = 2 * math.pi * p
    _, t = body(pose, pitch=4 * D + 1.5 * D * math.sin(w), roll=4 * D * math.sin(w), z=0.02 * math.sin(w))
    pose["neck"] = rx(-6 * D)
    pose["head"] = rx(-2 * D + 2 * D * math.sin(2 * w)) @ ry(-3 * D * math.sin(w))
    pose["tail"] = rx(-5 * D) @ rz(4 * D * math.sin(w + 1))
    for s, n in SIDES:
        pose[f"wing_{n}"] = spread(s, 8 * D + 2 * D * math.sin(2 * w + s))
        pose[f"hand_{n}"] = spread(s, 5 * D + 4 * D * math.sin(2 * w - 0.8)) @ rx(3 * D * math.sin(3 * w + s))
        pose[f"thigh_{n}"] = rx(-70 * D)
        pose[f"shin_{n}"] = rx(-50 * D)
        pose[f"foot_{n}"] = rx(-30 * D)
    return pose, t


def swim(p):
    """Floating like a duck: player.gd keeps the body centre FLOAT_DEPTH under the surface, i.e. the water
    at z ≈ 1.3 here, so the body rides 0.32 m up to sit in it to mid-height; legs paddle underneath."""
    pose = {}
    w = 2 * math.pi * p
    r, t = body(pose, pitch=5 * D + 1.5 * D * math.sin(2 * w), roll=3 * D * math.sin(w),
                z=0.32 + 0.015 * math.sin(2 * w))
    pose["neck"] = rx(-4 * D + 3 * D * math.sin(2 * w + 1))
    pose["head"] = rx(4 * D - 3 * D * math.sin(2 * w + 1)) @ rz(12 * D * math.sin(w * 0.5 + 0.3))
    pose["tail"] = rx(-15 * D) @ rz(8 * D * math.sin(w + 0.5))
    for s, n in SIDES:
        k = w + (0.0 if s > 0 else math.pi)  # alternate strokes
        pose[f"wing_{n}"] = ry(-s * 6 * D) @ fold(s)
        pose[f"thigh_{n}"] = r.inverted() @ rx(-25 * D + 30 * D * math.sin(k))
        pose[f"shin_{n}"] = rx(-35 * D + 25 * D * math.cos(k))
        pose[f"foot_{n}"] = rx(-10 * D - 35 * D * math.cos(k))  # paddle open on the back stroke
    return pose, t


ANIMS = [("idle", 150, idle), ("walk", 9, walk), ("run", 8, run), ("flap", 30, flap), ("glide", 120, glide),
         ("swim", 72, swim)]


# --- Rig, keys, export --------------------------------------------------------------------------

def rig():
    arm = bpy.data.objects.new("hen_rig", bpy.data.armatures.new("hen_rig"))
    bpy.context.scene.collection.objects.link(arm)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for name, head, tail, parent in BONES:
        eb = arm.data.edit_bones.new(name)
        eb.head, eb.tail, eb.roll = Vector(head), Vector(tail), 0.0
        if parent:
            eb.parent = arm.data.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return arm


def keys(arm, name, frames, fn):
    """One action, keyed on every frame from 0 to `frames` (the same pose: a seamless loop)."""
    arm.animation_data_create()
    arm.animation_data.action = bpy.data.actions.new(name + "-loop")  # Godot strips "-loop" and loops it
    rest = {b.name: b.matrix_local.to_3x3() for b in arm.data.bones}
    prev = {}
    for f in range(frames + 1):
        pose, t = fn(f / frames)
        for b in arm.pose.bones:
            r = rest[b.name]
            q = (r.inverted() @ pose.get(b.name, Matrix.Identity(3)) @ r).to_quaternion()
            if b.name in prev and prev[b.name].dot(q) < 0:
                q.negate()  # no flips between keys
            prev[b.name] = q
            b.rotation_quaternion = q
            b.keyframe_insert("rotation_quaternion", frame=f)
        b = arm.pose.bones["body"]
        b.location = rest["body"].inverted() @ t
        b.keyframe_insert("location", frame=f)
    arm.animation_data.action.use_fake_user = True


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps = FPS
os.makedirs(OUT, exist_ok=True)
arm = rig()
obj = bpy.data.objects.new("hen", build_mesh())
bpy.context.scene.collection.objects.link(obj)
for name, *_ in BONES:  # GROUP order
    obj.vertex_groups.new(name=name)
obj.parent = arm
obj.modifiers.new("rig", "ARMATURE").object = arm
for anim in ANIMS:
    keys(arm, *anim)
arm.animation_data.action = None
for b in arm.pose.bones:  # export the rest pose as the bind pose
    b.rotation_quaternion = (1, 0, 0, 0)
    b.location = (0, 0, 0)
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True)
obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "hen.glb"), export_format="GLB", use_selection=True,
                          export_yup=True, export_vertex_color="NAME", export_vertex_color_name="Col",
                          export_all_vertex_colors=False, export_animation_mode="ACTIONS")
