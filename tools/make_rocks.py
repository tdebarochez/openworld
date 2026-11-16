"""Generate the five low-poly rock models (boulder, slab, standing stone, pebble, cluster) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_rocks.py
Then: godot --headless --path . --import

Each rock is a convex hull (or a few fused hulls) of jittered points on a squashed sphere, flat shaded,
one stone material plus an optional moss material on upward-facing facets. Origin at the base centre,
Y up after export, the bottom ~15% of the rock sits below y=0 so it looks embedded in uneven ground.
Seeded, so re-running gives the same models.
"""
import math
import os
import random

import bmesh
import bpy
from mathutils import Euler, Vector

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "rocks")
STONE, MOSS = 0, 1
SINK = 0.15  # fraction of the rock's height below the origin
GOLDEN = math.pi * (3 - math.sqrt(5))


def linear(srgb):
    """Blender/glTF colours are linear; the palette below is picked in sRGB like the rest of the game."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def material(name, srgb):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*linear(srgb), 1.0)
    bsdf.inputs["Roughness"].default_value = 0.95
    return m


def stone(bm, rng, size, n, centre=(0, 0, 0), rot=(0, 0, 0), jitter=0.15, taper=0.0, cuts=()):
    """Convex hull of `n` points spread evenly over an ellipsoid of half-extents `size`, radially jittered.
    `taper` narrows the top; each cut (normal, k) flattens everything beyond the plane p.n = k (in unit
    sphere space) onto it, leaving a broad flat facet like a fractured face."""
    spin = rng.uniform(0, 2 * math.pi)
    cuts = [(Vector(nrm).normalized(), k) for nrm, k in cuts]
    verts = []
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        r = math.sqrt(1 - z * z)
        a = spin + i * GOLDEN
        d = Vector((r * math.cos(a), r * math.sin(a), z)) * rng.uniform(1 - jitter, 1 + jitter)
        for nrm, k in cuts:
            over = d.dot(nrm) - k
            if over > 0:
                d -= nrm * (over - rng.uniform(0, 0.03))
        squeeze = 1 - taper * (d.z + 1) / 2
        p = Vector((d.x * size[0] * squeeze, d.y * size[1] * squeeze, d.z * size[2]))
        verts.append(bm.verts.new(Euler(rot).to_matrix() @ p + Vector(centre)))
    hull = bmesh.ops.convex_hull(bm, input=verts)
    loose = {v for v in hull["geom_interior"] + hull["geom_unused"] if isinstance(v, bmesh.types.BMVert)}
    bmesh.ops.delete(bm, geom=list(loose), context="VERTS")


def boulder(bm, rng):
    stone(bm, rng, (1.15, 0.95, 0.85), 30, jitter=0.12, cuts=[((0.3, -0.2, 1), 0.75), ((1, 0.4, 0.1), 0.8)])


def slab(bm, rng):
    stone(bm, rng, (1.2, 0.85, 0.32), 24, rot=(0.06, -0.04, 0), jitter=0.1,
          cuts=[((0, 0, 1), 0.55), ((-1, 0.3, 0), 0.85)])


def standing(bm, rng):
    stone(bm, rng, (0.52, 0.42, 1.1), 26, centre=(0, 0, 1.0), rot=(0.08, -0.1, 0), jitter=0.16, taper=0.3,
          cuts=[((0.6, 0.2, 1), 0.55), ((-1, 0, 0), 0.8)])
    # A shard split off and leaning against the main column breaks the convex silhouette.
    stone(bm, rng, (0.28, 0.22, 0.6), 14, centre=(0.4, -0.15, 0.55), rot=(0.1, 0.35, 0.4), jitter=0.15, taper=0.4)


def pebble(bm, rng):
    stone(bm, rng, (0.36, 0.28, 0.22), 16, jitter=0.12, cuts=[((0.2, 0, 1), 0.7)])


def cluster(bm, rng):
    stone(bm, rng, (0.75, 0.6, 0.55), 20, centre=(-0.2, 0, 0.1), jitter=0.13, cuts=[((0, 0, 1), 0.75)])
    stone(bm, rng, (0.5, 0.42, 0.38), 16, centre=(0.65, 0.3, -0.05), rot=(0, 0.2, 0.5), jitter=0.15)
    stone(bm, rng, (0.38, 0.32, 0.3), 14, centre=(0.25, -0.6, -0.1), rot=(0.25, 0, 0.9), jitter=0.15)


def build(name, fn, seed, grey, moss=None):
    rng = random.Random(seed)
    bm = bmesh.new()
    fn(bm, rng)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    xs, ys, zs = ([v.co[i] for v in bm.verts] for i in range(3))
    h = max(zs) - min(zs)
    shift = Vector(((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, min(zs) + SINK * h))
    for v in bm.verts:
        v.co -= shift
    for f in bm.faces:
        f.smooth = False
        f.material_index = MOSS if moss and f.normal.z > 0.75 else STONE
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    print(f"{name}: {len(bm.faces)} faces, {sum(len(f.verts) - 2 for f in bm.faces)} triangles, "
          f"{max(xs) - min(xs):.2f} x {max(ys) - min(ys):.2f} x {h:.2f} m")
    bm.free()
    mesh.materials.append(material(name + "_stone", grey))
    if moss:
        mesh.materials.append(material(name + "_moss", moss))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, name + ".glb"), export_format="GLB",
                              use_selection=True, export_yup=True)


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
MOSSY = (0.36, 0.42, 0.26)
build("rock_0", boulder, 10, (0.45, 0.43, 0.41), MOSSY)
build("rock_1", slab, 11, (0.5, 0.48, 0.45), MOSSY)
build("rock_2", standing, 12, (0.42, 0.41, 0.40))
build("rock_3", pebble, 13, (0.48, 0.46, 0.43))
build("rock_4", cluster, 14, (0.44, 0.42, 0.40), MOSSY)
