"""Generate low-poly tree models (3 variants each of conifer, oak, birch) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_trees.py
Then: godot --headless --path . --import

Writes assets/trees/<species>_<n>.glb. Each model is one mesh with two materials (bark, leaves),
trunk base at the origin, Y up after export. Seeded, so re-running gives the same models.
Variants differ by shape parameters (branching, crown, tiers, lean), not just by seed.
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


def clump(bm, centre, radius, squash, rng, segs=7):
    """Lumpy foliage blob: coarse UV sphere (segs*6 triangles) with jittered vertices, flat shaded."""
    m = Matrix.Translation(centre) @ Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ Matrix.Diagonal((1, 1, squash, 1))
    res = bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=4, radius=radius, matrix=m)
    for v in res["verts"]:
        v.co += (v.co - centre).normalized() * radius * rng.uniform(-0.18, 0.18)
    for f in {f for v in res["verts"] for f in v.link_faces}:
        f.material_index = LEAVES


def lerp_radii(r0, r1, n):
    return [r0 + (r1 - r0) * i / (n - 1) for i in range(n)]


def oak(bm, rng, p):
    """Thick crooked trunk, a few heavy branches, wide clumpy crown."""
    trunk = wander_path(Vector((0, 0, 0)), p["lean"], p["height"], 4, 0.12, rng)
    tube(bm, trunk, lerp_radii(p["r"], p["r"] * 0.65, 5), 6, seed=1)
    n = p["branches"]
    for i in range(n):
        ang = p["spin"] + math.tau * i / n + rng.uniform(-0.3, 0.3)
        out = Vector((math.cos(ang), math.sin(ang), rng.uniform(*p["rise"])))
        br = wander_path(trunk[rng.randint(*p["fork"])], out, rng.uniform(*p["reach"]), 3, 0.25, rng)
        tube(bm, br, lerp_radii(p["r"] * 0.4, 0.06, 4), 4, seed=10 + i)
        clump(bm, br[-1] + Vector((0, 0, 0.4)), rng.uniform(*p["tip"]), p["squash"], rng, 8)
        if i < p["mid"]:
            clump(bm, br[1] + Vector((0, 0, 0.7)), rng.uniform(0.8, 1.0), p["squash"], rng, 6)
    for offset, radius in p["top"]:
        clump(bm, trunk[-1] + Vector(offset), radius, p["squash"], rng, 8)


def birch(bm, rng, p):
    """Thin white stem(s), short upward twigs each ending in a small elongated clump."""
    for j, (lean, length, forks) in enumerate(p["stems"]):
        segs = max(forks) + 1
        trunk = wander_path(Vector((0, 0, 0)), Vector(lean), length, segs, 0.06, rng)
        tube(bm, trunk, lerp_radii(p["r"], 0.04, segs + 1), 5, bumpy=0.08, seed=2 + j)
        spin = rng.uniform(0, math.tau)
        for i, k in enumerate(forks):
            ang = spin + i * 2.4 + rng.uniform(-0.4, 0.4)  # golden-angle spread keeps the crown balanced
            out = Vector((math.cos(ang), math.sin(ang), rng.uniform(0.9, 1.6)))
            br = wander_path(trunk[k], out, rng.uniform(*p["reach"]), 2, 0.2, rng)
            tube(bm, br, lerp_radii(0.05, 0.02, 3), 4, bumpy=0.0, seed=20 + 10 * j + i)
            clump(bm, br[-1] + Vector((0, 0, 0.3)), rng.uniform(*p["leaf"]), p["squash"], rng, 6)
        for dz, radius in p["top"]:
            clump(bm, trunk[-1] + Vector((0, 0, dz)), radius, p["squash"], rng, 6)


def whorl(bm, centre, radius, depth, segs, droop, rng):
    """One conifer tier: a star-rimmed cone (alternating branch tips and notches) over a hollow umbrella underside."""
    rot = rng.uniform(0, math.tau)
    apex = bm.verts.new(centre + Vector((0, 0, depth)))
    under = bm.verts.new(centre + Vector((0, 0, depth * 0.3)))
    rim = []
    for s in range(segs):
        a = rot + math.tau * s / segs
        if s % 2 == 0:  # branch tip: out and drooping
            r, dz = radius * rng.uniform(0.9, 1.1), -droop * rng.uniform(0.7, 1.3)
        else:  # notch between branches: in and higher
            r, dz = radius * rng.uniform(0.6, 0.72), droop * 0.2
        rim.append(bm.verts.new(centre + Vector((math.cos(a) * r, math.sin(a) * r, dz))))
    faces = []
    for s in range(segs):
        faces.append(bm.faces.new((rim[s], rim[(s + 1) % segs], apex)))
        faces.append(bm.faces.new((rim[(s + 1) % segs], rim[s], under)))
    for f in faces:
        f.material_index = LEAVES


def conifer(bm, rng, p):
    """Straight trunk with stacked drooping whorls shrinking towards the top."""
    lean = Vector((p["lean"], 0, 1))
    z, radius, depth = p["z0"], p["radius"], p["depth"]
    for _ in range(p["tiers"]):
        whorl(bm, lean * z, radius, depth, p["segs"], p["droop"] * radius / p["radius"] + 0.1, rng)
        top = z + depth
        z += depth * p["step"]
        radius *= p["shrink"]
        depth *= 0.9
    trunk = wander_path(Vector((0, 0, 0)), lean, top * 0.8, 3, 0.02, rng)
    tube(bm, trunk, lerp_radii(p["r"], 0.06, 4), 5, bumpy=0.1, seed=3)


# species -> (builder, bark sRGB, leaves sRGB, [variant params]). Comments say what sets each variant apart.
SPECIES = {
    "conifer": (conifer, (0.4, 0.27, 0.15), (0.13, 0.36, 0.15), [
        # classic spruce: 5 even tiers from low down
        dict(tiers=5, z0=1.0, radius=1.9, depth=2.0, shrink=0.78, step=0.55, segs=10, droop=0.35, lean=0.0, r=0.24),
        # tall narrow fir: 7 tight slim tiers
        dict(tiers=7, z0=0.6, radius=1.35, depth=2.0, shrink=0.85, step=0.6, segs=8, droop=0.25, lean=0.0, r=0.2),
        # old pine-like: bare lower trunk, 4 wide gappy heavily drooping tiers, slight lean
        dict(tiers=4, z0=2.4, radius=2.1, depth=1.4, shrink=0.72, step=0.8, segs=12, droop=0.6, lean=0.07, r=0.26),
    ]),
    "oak": (oak, (0.33, 0.24, 0.15), (0.24, 0.42, 0.12), [
        # round crown: 5 branches, domed top
        dict(height=2.9, lean=Vector((0, 0, 1)), r=0.42, branches=5, fork=(2, 4), rise=(0.6, 1.1), reach=(1.6, 2.2),
             tip=(1.05, 1.35), mid=2, squash=0.75, spin=0.0, top=[((0, 0, 1.8), 1.6)]),
        # spreading: short stout trunk, 4 long low near-horizontal limbs, flat wide crown
        dict(height=2.4, lean=Vector((0, 0, 1)), r=0.48, branches=4, fork=(2, 3), rise=(0.35, 0.55), reach=(2.6, 3.0),
             tip=(1.2, 1.45), mid=4, squash=0.6, spin=0.4, top=[((0, 0, 1.7), 1.6)]),
        # tall leaning: 3 upswept branches, lopsided stacked crown
        dict(height=3.4, lean=Vector((0.22, 0.08, 1)), r=0.38, branches=3, fork=(3, 4), rise=(1.2, 1.7), reach=(1.4, 1.9),
             tip=(1.0, 1.25), mid=3, squash=0.8, spin=1.0, top=[((0.3, 0, 1.4), 1.4), ((-0.4, 0.3, 2.6), 1.0)]),
    ]),
    "birch": (birch, (0.88, 0.87, 0.82), (0.5, 0.68, 0.22), [
        # single straight stem, twigs spread up the top half
        dict(stems=[((0.05, 0, 1), 6.0, (3, 3, 4, 4))], r=0.14, reach=(0.8, 1.4), leaf=(0.55, 0.8), squash=1.4,
             top=[(0.4, 0.8)]),
        # tall slender leaner: twigs only near the top, narrow columnar crown
        dict(stems=[((0.2, 0.05, 1), 5.6, (4, 5, 5))], r=0.12, reach=(0.5, 0.8), leaf=(0.45, 0.6), squash=1.9,
             top=[(0.3, 0.6), (1.2, 0.45)]),
        # twin stem: two diverging trunks from the base
        dict(stems=[((0.3, 0, 1), 5.8, (2, 3)), ((-0.25, 0.15, 1), 4.8, (3,))], r=0.11, reach=(0.7, 1.1),
             leaf=(0.5, 0.7), squash=1.4, top=[(0.35, 0.7)]),
    ]),
}


def build(name, fn, params, seed, bark, leaves):
    rng = random.Random(seed)
    bm = bmesh.new()
    fn(bm, rng, params)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Face order out of bmesh ops varies between runs and the exporter keeps it as triangle order:
    # triangulate and sort by position so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    height = max(v.co.z for v in bm.verts)
    print(f"{name}: {len(bm.faces)} faces, {sum(len(f.verts) - 2 for f in bm.faces)} triangles, {height:.2f} m tall")
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
for s, (species, (fn, bark, leaves, variants)) in enumerate(SPECIES.items()):
    for i, params in enumerate(variants):
        build(f"{species}_{i}", fn, params, 10 * (s + 1) + i, bark, leaves)
