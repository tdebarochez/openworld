"""Generate the three low-poly tree models (conifer, oak, birch) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_trees.py
Then: godot --headless --path . --import

Each model is one mesh with two materials (bark, leaves), trunk base at the origin, Y up after export.
Seeded, so re-running gives the same models.
"""
import math
import os
import random

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "trees")
BARK, LEAVES = 0, 1


def linear(srgb):
    """Blender/glTF colours are linear; the palette below is picked in sRGB like the rest of the game."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def material(name, srgb):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*linear(srgb), 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    return m


def tube(bm, path, radii, sides, bumpy=0.15, seed=0.0):
    """Closed-top tube along `path`; radius wobbles with noise so trunks look irregular."""
    d = (path[1] - path[0]).normalized()
    a = d.orthogonal().normalized()
    rings = []
    for i, p in enumerate(path):
        d = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
        a = (a - d * a.dot(d)).normalized()  # parallel transport: no twist between rings
        b = d.cross(a)
        ring = []
        for s in range(sides):
            ang = 2 * math.pi * s / sides
            r = radii[i] * (1 + bumpy * noise.noise(p * 2.5 + Vector((s * 1.7, seed, 0))))
            ring.append(bm.verts.new(p + (a * math.cos(ang) + b * math.sin(ang)) * r))
        rings.append(ring)
    faces = []
    for r0, r1 in zip(rings, rings[1:]):
        for s in range(sides):
            faces.append(bm.faces.new((r0[s], r0[(s + 1) % sides], r1[(s + 1) % sides], r1[s])))
    faces.append(bm.faces.new(rings[-1]))
    for f in faces:
        f.material_index = BARK
        f.smooth = True


def wander_path(start, direction, length, segments, wobble, rng):
    """Points from `start` along `direction`, each step nudged sideways: a crooked branch."""
    pts = [start.copy()]
    step = length / segments
    d = direction.normalized()
    for _ in range(segments):
        d = (d + Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.3, 0.6))) * wobble).normalized()
        pts.append(pts[-1] + d * step)
    return pts


def clump(bm, centre, radius, squash, rng):
    """Lumpy foliage blob: subdivided icosahedron with jittered vertices, flat shaded."""
    m = Matrix.Translation(centre) @ Matrix.Diagonal((1, 1, squash, 1))
    res = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=radius, matrix=m)
    for v in res["verts"]:
        v.co += (v.co - centre).normalized() * radius * rng.uniform(-0.18, 0.18)
    for f in {f for v in res["verts"] for f in v.link_faces}:
        f.material_index = LEAVES


def lerp_radii(r0, r1, n):
    return [r0 + (r1 - r0) * i / (n - 1) for i in range(n)]


def oak(bm, rng):
    trunk = wander_path(Vector((0, 0, 0)), Vector((0, 0, 1)), 2.6, 4, 0.12, rng)
    tube(bm, trunk, lerp_radii(0.42, 0.28, 5), 7, seed=1)
    top = trunk[-1]
    n = 5
    for i in range(n):
        ang = 2 * math.pi * i / n + rng.uniform(-0.3, 0.3)
        out = Vector((math.cos(ang), math.sin(ang), rng.uniform(0.6, 1.1)))
        start = trunk[rng.randint(2, 4)]
        br = wander_path(start, out, rng.uniform(1.6, 2.4), 3, 0.25, rng)
        tube(bm, br, lerp_radii(0.17, 0.06, 4), 5, seed=10 + i)
        clump(bm, br[-1] + Vector((0, 0, 0.4)), rng.uniform(1.1, 1.5), 0.75, rng)
        clump(bm, br[1] + Vector((0, 0, 0.7)), rng.uniform(0.8, 1.0), 0.75, rng)
    clump(bm, top + Vector((0, 0, 1.6)), 1.6, 0.7, rng)


def birch(bm, rng):
    trunk = wander_path(Vector((0, 0, 0)), Vector((0.05, 0, 1)), 6.0, 6, 0.06, rng)
    tube(bm, trunk, lerp_radii(0.14, 0.05, 7), 6, bumpy=0.08, seed=2)
    for i, k in enumerate((2, 3, 3, 4, 5)):
        ang = rng.uniform(0, 2 * math.pi)
        out = Vector((math.cos(ang), math.sin(ang), rng.uniform(0.9, 1.6)))
        br = wander_path(trunk[k], out, rng.uniform(0.8, 1.4), 2, 0.2, rng)
        tube(bm, br, lerp_radii(0.05, 0.02, 3), 4, bumpy=0.0, seed=20 + i)
        clump(bm, br[-1] + Vector((0, 0, 0.3)), rng.uniform(0.55, 0.8), 1.4, rng)
    clump(bm, trunk[-1] + Vector((0, 0, 0.4)), 0.8, 1.5, rng)


def conifer(bm, rng):
    trunk = wander_path(Vector((0, 0, 0)), Vector((0, 0, 1)), 5.5, 4, 0.03, rng)
    tube(bm, trunk, lerp_radii(0.24, 0.06, 5), 6, bumpy=0.1, seed=3)
    # Stacked whorls of branches: each tier is a cone whose rim droops unevenly.
    z, radius, depth = 1.1, 1.9, 2.0
    for tier in range(5):
        res = bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=9,
                                    radius1=radius, radius2=0.0, depth=depth,
                                    matrix=Matrix.Translation((0, 0, z + depth / 2)) @ Matrix.Rotation(rng.uniform(0, 1), 4, "Z"))
        for v in res["verts"]:
            if v.co.z < z + 0.01:  # rim: jagged branch tips
                v.co.z -= rng.uniform(0.0, 0.35)
                v.co.xy *= rng.uniform(0.85, 1.1)
        for f in {f for v in res["verts"] for f in v.link_faces}:
            f.material_index = LEAVES
        z += depth * 0.55
        radius *= 0.78
        depth *= 0.88


def build(name, fn, seed, bark, leaves):
    rng = random.Random(seed)
    bm = bmesh.new()
    fn(bm, rng)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    print(f"{name}: {len(bm.faces)} faces, {sum(len(f.verts) - 2 for f in bm.faces)} triangles")
    bm.free()
    mesh.materials.append(material(name + "_bark", bark))
    mesh.materials.append(material(name + "_leaves", leaves))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, name + ".glb"), export_format="GLB",
                              use_selection=True, export_yup=True)


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
build("conifer", conifer, 1, (0.4, 0.27, 0.15), (0.13, 0.36, 0.15))
build("oak", oak, 2, (0.33, 0.24, 0.15), (0.24, 0.42, 0.12))
build("birch", birch, 3, (0.88, 0.87, 0.82), (0.5, 0.68, 0.22))
