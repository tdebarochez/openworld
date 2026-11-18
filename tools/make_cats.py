"""Generate the two low-poly cat models (sitting, lying) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_cats.py
Then: godot --headless --path . --import

Writes assets/cats/cat_<pose>.glb. Origin = the top of a bench seat's front edge under the cat's middle,
the seat running along X and behind the edge (Godot -Z), so world.gd puts the origin on the edge.
The tail lies on the seat, then hangs over the edge into the air. Surfaces: 0 = coat (cream here,
replaced in game by world.gd's cat shader, coloured per instance), 1 = eyes, 2 = nose.
Vertex colour (COLOR_0): rgb = baked shading (tools/make_trees.py bake_shade), alpha = how much the
vertex swings with the tail (0 on the body and on the seat, 1 at the tip), UV = the swing's pivot in
the Godot x/y plane (where the tail leaves the seat): world.gd's shader swings it around Z.
Seeded and sorted, so re-running gives the same files.
"""
import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_trees import bake_shade, export, material, tube  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "cats")
COAT, EYES, NOSE = 0, 1, 2
PIVOT_Z = -0.02  # m below the seat top: the tail swings from here down
HANG = 0.16  # m of tail below the pivot over which the swing grows from 0 to 1
# Blender axes: X along the bench, -Y = out of the seat's front edge (Godot +Z), Z up; y >= 0 is the seat.


def blob(bm, c, r, mat=COAT, segs=10, rings=6, tilt=0.0):
    """Smooth low-poly ellipsoid at `c` with half-extents `r`, tipped `tilt` rad about X (top towards -Y)."""
    m = Matrix.Translation(c) @ Matrix.Rotation(tilt, 4, "X") @ Matrix.Diagonal((*r, 1))
    res = bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=1.0, matrix=m)
    for f in {f for v in res["verts"] for f in v.link_faces}:
        f.material_index = mat
        f.smooth = True


def on(c, r, d):
    """Point of ellipsoid (c, r) in direction d."""
    d = Vector(d).normalized()
    return Vector(c) + Vector((d.x * r[0], d.y * r[1], d.z * r[2]))


def head(bm, c, r=(0.08, 0.072, 0.068)):
    """Round head facing -Y: muzzle, nose, green eyes and two triangular ears tipped outwards."""
    blob(bm, c, r)
    muzzle = on(c, r, (0, -1, -0.35)) + Vector((0, 0.012, 0))
    blob(bm, muzzle, (0.038, 0.024, 0.026), segs=8, rings=4)
    blob(bm, on(muzzle, (0.038, 0.024, 0.026), (0, -1, 0.6)), (0.01, 0.007, 0.008), NOSE, 6, 4)
    for s in (1, -1):
        blob(bm, on(c, r, (0.42 * s, -1, 0.28)), (0.014, 0.008, 0.016), EYES, 6, 4)
        base = on(c, r, (0.55 * s, 0.1, 0.85))
        rot = Matrix.Rotation(-0.35 * s, 4, "Y") @ Matrix.Rotation(math.pi / 6, 4, "Z")
        cone = bmesh.ops.create_cone(bm, cap_ends=True, segments=3, radius1=0.034, radius2=0.0, depth=0.07,
                                     matrix=Matrix.Translation(base + Vector((0, 0, 0.022))) @ rot)
        for f in {f for v in cone["verts"] for f in v.link_faces}:
            f.material_index = COAT
            f.smooth = False


def sitting(bm):
    """Upright on its haunches facing out of the bench, front paws together, tail round its right side."""
    blob(bm, (0, 0.15, 0.075), (0.095, 0.1, 0.09))  # haunches, sunk 1.5 cm into the seat
    blob(bm, (0, 0.095, 0.15), (0.068, 0.07, 0.1), tilt=0.15)  # chest
    head(bm, Vector((0, 0.075, 0.29)))
    for s in (1, -1):
        blob(bm, (0.032 * s, 0.035, 0.012), (0.024, 0.04, 0.02), segs=8, rings=4)  # front paws
    return [(0, 0.2, 0.05), (0.07, 0.25, 0.022), (0.115, 0.2, 0.022), (0.125, 0.12, 0.022), (0.11, 0.05, 0.024),
            (0.09, 0.015, 0.03), (0.075, -0.035, 0.015), (0.07, -0.045, -0.04), (0.07, -0.045, -0.08),
            (0.072, -0.044, -0.12), (0.076, -0.042, -0.155), (0.083, -0.04, -0.18), (0.092, -0.038, -0.195)]


def lying(bm):
    """A loaf along the bench, head up at +X looking out, paws peeking out front, tail off the left end."""
    blob(bm, (0, 0.14, 0.065), (0.17, 0.1, 0.08))  # body
    blob(bm, (-0.09, 0.15, 0.075), (0.09, 0.1, 0.085))  # haunch
    blob(bm, (0.1, 0.12, 0.07), (0.08, 0.085, 0.075))  # chest
    head(bm, Vector((0.17, 0.095, 0.155)))
    for x in (0.12, 0.2):
        blob(bm, (x, 0.045, 0.012), (0.024, 0.04, 0.018), segs=8, rings=4)  # front paws
    return [(-0.15, 0.15, 0.05), (-0.2, 0.15, 0.025), (-0.235, 0.11, 0.022), (-0.245, 0.06, 0.022),
            (-0.235, 0.02, 0.028), (-0.225, -0.035, 0.015), (-0.22, -0.045, -0.04), (-0.22, -0.045, -0.08),
            (-0.218, -0.044, -0.12), (-0.212, -0.042, -0.15), (-0.203, -0.04, -0.17), (-0.192, -0.038, -0.18)]


def build(name, fn):
    bm = bmesh.new()
    path = [Vector(p) for p in fn(bm)]
    before = set(bm.verts)
    n = len(path)
    tube(bm, path, [0.022 - 0.008 * i / (n - 1) for i in range(n)], 6, bumpy=0.0)  # material 0 = coat
    tail = set(bm.verts) - before
    pivot = next(p for p in path if p.z < PIVOT_Z)  # the hanging column's x
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Same triangulate-and-sort as make_trees.build, so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    bake_shade(bm, 0.12, strength=0.5, base=0.85)
    col = bm.loops.layers.float_color["Col"]
    uv = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        for loop in f.loops:
            v = loop.vert
            w = min(max((PIVOT_Z - v.co.z) / HANG, 0.0), 1.0) if v in tail else 0.0
            loop[col] = (*loop[col][:3], w)
            loop[uv].uv = (pivot.x, 1.0 - PIVOT_Z)  # glTF flips V: Godot reads UV = (x, PIVOT_Z)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    print(f"{name}: {sum(len(f.verts) - 2 for f in bm.faces)} triangles, "
          f"{max(v.co.z for v in bm.verts):.2f} m tall, pivot x {pivot.x:.3f}")
    bm.free()
    for mat in (material(name + "_coat", "cream"), material(name + "_eyes", "leaf_light"), material(name + "_nose", "rose")):
        mesh.materials.append(mat)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
build("cat_sitting", sitting)  # world.CatPose order
build("cat_lying", lying)
