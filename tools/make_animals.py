"""Generate the grazing animals (sheep, cow) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_animals.py
Then: godot --headless --path . --import

Writes assets/animals/<species>.glb: soft low-poly blobs, standing on the ground at the origin, facing
Godot +Z (Blender -Y). One surface per palette colour; life.gd swaps each for its grazing shader.
Vertex colour (COLOR_0): rgb = baked shading (tools/make_trees.py bake_shade), alpha = what moves:
1 = head and neck (turned down about the X axis around the pivot, to graze), 0 < a <= 0.5 = tail
(swung sideways, 2a times the flick), 0 = still. UV = the head pivot in the Godot y/z plane (the neck's
root, buried in the chest so no seam opens). Deterministic, so re-running gives the same files.
"""
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_trees import bake_shade, export, material, tube  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "animals")
STILL, HEAD, TAIL = 0, 1, 2


class Animal:
    """bmesh plus the part (STILL, HEAD, TAIL) of every vertex and the palette colour of every face."""

    def __init__(self, colours):
        self.bm = bmesh.new()
        self.colours = colours  # material slot → palette name
        self.part = {}

    def blob(self, c, r, colour, part=STILL, segs=10, rings=6, tilt=0.0):
        """Smooth ellipsoid at `c` with half-extents `r`, tipped `tilt` rad about X (front down)."""
        m = Matrix.Translation(c) @ Matrix.Rotation(tilt, 4, "X") @ Matrix.Diagonal((*r, 1))
        res = bmesh.ops.create_uvsphere(self.bm, u_segments=segs, v_segments=rings, radius=1.0, matrix=m)
        self._own(res["verts"], colour, part)

    def tail(self, path, r0, r1, tuft=None):
        """Tapering tube along `path` (weight growing to the tip), with an optional tuft colour at the end."""
        before = set(self.bm.verts)
        n = len(path)
        tube(self.bm, [Vector(p) for p in path], [r0 + (r1 - r0) * i / (n - 1) for i in range(n)], 6, bumpy=0.0)
        self._own(set(self.bm.verts) - before, self.colours[0], TAIL)
        top = Vector(path[0])
        span = (Vector(path[-1]) - top).length
        for v in set(self.bm.verts) - before:
            self.part[v] = (TAIL, min((v.co - top).length / span, 1.0))
        if tuft:
            before = set(self.bm.verts)
            self.blob(Vector(path[-1]) + Vector((0, 0, -0.04)), (r1 * 2.2, r1 * 2.2, 0.08), tuft, TAIL, 8, 4)
            for v in set(self.bm.verts) - before:
                self.part[v] = (TAIL, 1.0)

    def _own(self, verts, colour, part):
        slot = self.colours.index(colour)
        for v in verts:
            self.part[v] = (part, 1.0)
        for f in {f for v in verts for f in v.link_faces}:
            f.material_index = slot
            f.smooth = True


def sheep():
    """Round woolly sheep with a black face and legs: a cloud of wool on four sticks."""
    a = Animal(["cream", "ink"])
    for x in (0.13, -0.13):
        for y in (-0.24, 0.27):
            a.blob((x, y, 0.22), (0.045, 0.05, 0.24), "ink", segs=6, rings=4)
    a.blob((0, 0.02, 0.6), (0.3, 0.48, 0.27), "cream")  # body
    for c, r in [((0.0, -0.18, 0.78), (0.22, 0.24, 0.16)), ((0.0, 0.2, 0.77), (0.23, 0.25, 0.16)),
                 ((0.17, 0.0, 0.66), (0.17, 0.32, 0.18)), ((-0.17, 0.0, 0.66), (0.17, 0.32, 0.18)),
                 ((0.0, 0.42, 0.62), (0.22, 0.14, 0.2))]:  # lumps of wool
        a.blob(c, r, "cream", segs=8, rings=5)
    a.blob((0, -0.45, 0.69), (0.16, 0.22, 0.17), "cream", HEAD, segs=8, rings=5)  # neck in its wool
    a.blob((0, -0.7, 0.68), (0.1, 0.17, 0.11), "ink", HEAD, tilt=0.5)  # head, muzzle down a little
    a.blob((0, -0.62, 0.77), (0.1, 0.09, 0.07), "cream", HEAD, segs=8, rings=4)  # wool cap
    for s in (1, -1):
        a.blob((0.12 * s, -0.61, 0.73), (0.07, 0.03, 0.025), "ink", HEAD, segs=6, rings=4)  # ears
    a.tail([(0, 0.48, 0.66), (0, 0.53, 0.58), (0, 0.55, 0.5)], 0.06, 0.04)
    return a, Vector((0, -0.3, 0.6))


def cow():
    """Red-pied cow: ginger coat, cream legs and face, pink muzzle and udder, little horns, a gold bell."""
    a = Animal(["ginger", "cream", "rose", "gold", "ink"])
    for x in (0.2, -0.2):
        for y in (-0.55, 0.6):
            a.blob((x, y, 0.38), (0.075, 0.085, 0.4), "cream", segs=8, rings=4)
            a.blob((x, y, 0.04), (0.08, 0.09, 0.05), "ink", segs=6, rings=3)  # hooves
    a.blob((0, 0.0, 0.94), (0.37, 0.8, 0.34), "ginger")  # barrel
    a.blob((0, 0.52, 0.98), (0.35, 0.32, 0.33), "ginger", segs=8, rings=5)  # haunch
    a.blob((0, -0.48, 0.96), (0.33, 0.32, 0.34), "ginger", segs=8, rings=5)  # chest
    a.blob((0, -0.05, 0.72), (0.27, 0.6, 0.18), "cream", segs=8, rings=5)  # pale belly
    a.blob((0.3, 0.15, 0.98), (0.1, 0.3, 0.2), "cream", segs=8, rings=4)  # patches
    a.blob((-0.28, -0.25, 1.02), (0.1, 0.26, 0.18), "cream", segs=8, rings=4)
    a.blob((0, 0.42, 0.62), (0.13, 0.12, 0.08), "rose", segs=8, rings=4)  # udder
    a.blob((0, -0.8, 1.06), (0.2, 0.32, 0.25), "ginger", HEAD, segs=8, rings=5)  # neck
    a.blob((0, -1.15, 1.08), (0.15, 0.24, 0.16), "cream", HEAD, tilt=0.45)  # head
    a.blob((0, -1.36, 0.98), (0.12, 0.08, 0.09), "rose", HEAD, segs=8, rings=4)  # muzzle
    for s in (1, -1):
        a.blob((0.21 * s, -1.02, 1.17), (0.09, 0.035, 0.05), "ginger", HEAD, segs=6, rings=4)  # ears
        a.blob((0.13 * s, -1.06, 1.26), (0.07, 0.025, 0.025), "cream", HEAD, segs=6, rings=3)  # horns
    a.blob((0, -0.86, 0.78), (0.06, 0.06, 0.08), "gold", HEAD, segs=8, rings=4)  # bell
    a.tail([(0, 0.82, 1.18), (0, 0.9, 1.0), (0, 0.92, 0.8), (0, 0.92, 0.62)], 0.035, 0.025, tuft="ink")
    return a, Vector((0, -0.55, 0.95))


def build(name, fn):
    a, pivot = fn()
    bm = a.bm
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    part = {v: a.part[v] for v in bm.verts}  # survive the triangulation (it keeps the verts)
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    bake_shade(bm, 0.3, strength=0.5, base=0.8)
    col = bm.loops.layers.float_color["Col"]
    uv = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        for loop in f.loops:
            kind, w = part[loop.vert]
            alpha = 1.0 if kind == HEAD else (0.5 * w if kind == TAIL else 0.0)
            loop[col] = (*loop[col][:3], alpha)
            loop[uv].uv = (pivot.z, 1.0 + pivot.y)  # Godot (y, z) = Blender (z, -y); glTF flips V
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    head = [v.co for v in bm.verts if part[v][0] == HEAD]
    reach = max((c - pivot).length for c in head)
    print(f"{name}: {len(bm.faces)} triangles, {max(v.co.z for v in bm.verts):.2f} m tall, "
          f"{max(v.co.y for v in bm.verts) - min(v.co.y for v in bm.verts):.2f} m long, head reach {reach:.2f} m "
          f"from a {pivot.z:.2f} m pivot")
    bm.free()
    for c in a.colours:
        mesh.materials.append(material(f"{name}_{c}", c))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
build("sheep", sheep)  # life.gd's Animal order
build("cow", cow)
