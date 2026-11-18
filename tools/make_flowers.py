"""Generate five low-poly flowering plants, one per part of the year, as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_flowers.py
Then: godot --headless --path . --import

Writes assets/flowers/<name>.glb and assets/flowers/flowers.json (bloom seasons, habitat, height, ...).
Each model is one small clump of at most 80 triangles, origin at the base centre, Y up after export,
darker at the foot (tools/make_trees.py bake_shade).
Material slots are fixed: 0 = foliage (stems, leaves, buds), 1 = blossom (petals), 2 = heart (optional).
The game hides slots >= 1 out of season, so slot 0 on its own must read as a plain green plant.
Seeded, so re-running gives byte-identical files.
"""
import json
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_trees import bake_shade, export  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "flowers")
FOLIAGE, BLOSSOM, HEART = 0, 1, 2
MAX_TRIS = 80
Z = Vector((0, 0, 1))
GOLDEN = math.pi * (3 - math.sqrt(5))


with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "palette.json")) as f:
    PALETTE = json.load(f)["colours"]


def linear(colour):
    """Blender/glTF colours are linear; the game's palette (assets/palette.json) is sRGB hex, by name."""
    srgb = (int(PALETTE[colour][i:i + 2], 16) / 255 for i in (1, 3, 5))
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def material(name, colour):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*linear(colour), 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    return m


def face(bm, verts, mat):
    f = bm.faces.new(verts)
    f.material_index = mat
    f.smooth = False


def heading(ang):
    return Vector((math.cos(ang), math.sin(ang), 0))


def basis(axis):
    a = axis.orthogonal().normalized()
    return a, axis.cross(a).normalized()


def stem(bm, path, r0, r1, sides=3):
    """Open tube along `path`, radius tapering r0 -> r1. No caps: the ends hide in the ground or the flower."""
    rings, a = [], None
    for i, p in enumerate(path):
        d = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
        a = d.orthogonal() if a is None else a
        a = (a - d * a.dot(d)).normalized()  # parallel transport: no twist between rings
        b = d.cross(a)
        r = r0 + (r1 - r0) * i / (len(path) - 1)
        rings.append([bm.verts.new(p + (a * math.cos(math.tau * s / sides) + b * math.sin(math.tau * s / sides)) * r)
                      for s in range(sides)])
    for q0, q1 in zip(rings, rings[1:]):
        for s in range(sides):
            face(bm, (q0[s], q0[(s + 1) % sides], q1[(s + 1) % sides], q1[s]), FOLIAGE)


def ribbon(bm, centres, sides, mat):
    """Flat strip through `centres`; sides[i] is the half-width vector there (zero length = pointed end)."""
    rows = [[bm.verts.new(c)] if s.length < 1e-6 else [bm.verts.new(c - s), bm.verts.new(c + s)]
            for c, s in zip(centres, sides)]
    for r0, r1 in zip(rows, rows[1:]):
        face(bm, r0 + r1[::-1], mat)


def leaf(bm, base, ang, length, width, rise, droop=0.0, segs=2, fold=0.4, peak=0.5):
    """Pointed leaf leaving `base` towards heading `ang`, `rise` radians above horizontal, tip sagging by `droop`
    (fraction of length), widest at `peak` of its length. The edges sit `fold` x half-width above the midrib:
    a shallow V channel."""
    d, side = heading(ang), heading(ang + math.pi / 2)
    centres, sides = [], []
    for i in range(segs + 1):
        t = i / segs
        w = width * math.sin(math.pi * t ** math.log(0.5, peak))
        centres.append(base + d * length * t * math.cos(rise) + Z * length * (t * math.sin(rise) - droop * t * t)
                       + Z * w * fold)
        sides.append(side * w)
    ribbon(bm, centres, sides, FOLIAGE)


def petal(bm, base, d, side, length, width, mat=BLOSSOM, at=0.55):
    """Diamond petal (2 triangles) from `base` along unit `d`, widest (`width` each side) at `at` of its length."""
    ribbon(bm, [base, base + d * length * at, base + d * length], [Vector(), side * width, Vector()], mat)


def ring(bm, centre, axis, radius, n, rot=0.0):
    a, b = basis(axis)
    return [bm.verts.new(centre + (a * math.cos(rot + math.tau * i / n) + b * math.sin(rot + math.tau * i / n)) * radius)
            for i in range(n)]


def fan(bm, verts, apex, mat):
    """Cone from a vertex ring to `apex`: len(verts) triangles."""
    tip = bm.verts.new(apex)
    for i in range(len(verts)):
        face(bm, (verts[i], verts[(i + 1) % len(verts)], tip), mat)


def snowdrop(bm, rng):
    """Three short stems arching over at the top, each hanging one white bell of three tepals around a green
    heart, with two narrow glaucous leaves each."""
    for k in range(3):
        ang = k * math.tau / 3 + rng.uniform(-0.4, 0.4)
        out = heading(ang)
        base = out * 0.02 - Z * 0.01
        top = base + Z * rng.uniform(0.12, 0.15) + out * 0.012
        tip = top + out * 0.022 - Z * 0.008  # pedicel arches over
        stem(bm, [base, top, tip], 0.0025, 0.0015)
        hang = (-Z + out * 0.25).normalized()
        a, b = basis(hang)
        for i in range(3):
            rad = a * math.cos(i * math.tau / 3) + b * math.sin(i * math.tau / 3)
            d = (hang + rad * 0.45).normalized()  # tepals flare a little
            petal(bm, tip, d, d.cross(rad).normalized(), 0.027, 0.009)
        fan(bm, ring(bm, tip + hang * 0.003, hang, 0.005, 3, math.pi / 3), tip + hang * 0.015, HEART)
        for j in (-1, 1):
            leaf(bm, base, ang + j * 0.6 + rng.uniform(-0.2, 0.2), rng.uniform(0.1, 0.13), 0.006, 1.2, 0.3)


def tulip(bm, rng):
    """Three straight stems each topped by a closed cup of six pointed tepals around a green seed pod (all that
    is left out of season); broad basal leaves."""
    for k in range(3):
        ang = k * math.tau / 3 + rng.uniform(-0.3, 0.3)
        out = heading(ang)
        base = out * 0.03 - Z * 0.02
        top = base + Z * (0.36 - 0.04 * k) + out * rng.uniform(0.02, 0.05)
        stem(bm, [base, top], 0.004, 0.003)
        axis = (top - base).normalized()
        a, b = basis(axis)
        spin = rng.uniform(0, math.tau)
        fan(bm, ring(bm, top, axis, 0.008, 3, spin), top + axis * 0.035, FOLIAGE)
        rim = ring(bm, top + axis * 0.024, axis, 0.021, 6, spin)
        fan(bm, rim, top, BLOSSOM)
        for i in range(6):  # tepal tips lean in over the rim gaps: a closed cup with notched top
            ta = spin + (i + 0.5) * math.tau / 6
            tipv = bm.verts.new(top + axis * (0.06 + 0.005 * (i % 2)) + (a * math.cos(ta) + b * math.sin(ta)) * 0.016)
            face(bm, (rim[i], rim[(i + 1) % 6], tipv), BLOSSOM)
    for j in range(4):
        leaf(bm, -Z * 0.01, j * math.tau / 4 + rng.uniform(-0.3, 0.3), rng.uniform(0.18, 0.24), 0.028, 0.95, 0.4,
             segs=3, fold=0.5, peak=0.35)


def poppy(bm, rng):
    """Two wiry stems with open four-petalled cups around a green seed capsule with a dark top, one nodding
    green bud, basal leaves. Out of season the capsules and the bud remain."""
    for k in range(3):
        ang = k * math.tau / 3 + rng.uniform(-0.4, 0.4)
        out, side = heading(ang), heading(ang + math.pi / 2)
        base = out * 0.03 - Z * 0.02
        h = (0.5, 0.42, 0.34)[k] * rng.uniform(0.95, 1.05)
        mid = base + Z * h * 0.55 + out * 0.04 + side * rng.uniform(-0.03, 0.03)
        if k < 2:
            top = base + Z * h + out * 0.08
            stem(bm, [base, mid, top], 0.003, 0.0025)
            axis = (Z + out * 0.3).normalized()
            a, b = basis(axis)
            spin = rng.uniform(0, math.tau)
            for i in range(4):
                rad = a * math.cos(spin + i * math.tau / 4) + b * math.sin(spin + i * math.tau / 4)
                d = (rad + axis * 0.8).normalized()  # cupped
                petal(bm, top, d, axis.cross(rad).normalized(), 0.05, 0.036, at=0.6)
            capsule = ring(bm, top + axis * 0.012, axis, 0.008, 4, spin + math.pi / 4)
            fan(bm, capsule, top, FOLIAGE)
            fan(bm, capsule, top + axis * 0.018, HEART)
        else:
            top = base + Z * h * 0.9 + out * 0.06
            tip = top + out * 0.03 - Z * 0.03  # bud stalk hooks over
            stem(bm, [base, top, tip], 0.003, 0.0025)
            hang = (tip - top).normalized()
            girdle = ring(bm, tip + hang * 0.012, hang, 0.007, 3)
            fan(bm, girdle, tip, FOLIAGE)
            fan(bm, girdle, tip + hang * 0.03, FOLIAGE)
    for j in range(3):
        leaf(bm, -Z * 0.01, j * math.tau / 3 + rng.uniform(-0.3, 0.3), rng.uniform(0.13, 0.17), 0.024, 0.5, 0.35)


def heather(bm, rng):
    """Low woody mound bristling with upright shoots; the upper half of each shoot is sheathed in tiny bells,
    with the green shoot tip poking out above them."""
    mound = [bm.verts.new(heading(i * math.tau / 6) * 0.18 * rng.uniform(0.85, 1.1) - Z * 0.01) for i in range(6)]
    fan(bm, mound, Z * 0.09, FOLIAGE)
    for i in range(8):
        out = heading(i * GOLDEN)
        base = out * 0.11 * math.sqrt((i + 0.5) / 8) + Z * 0.02
        d = (Z + out * rng.uniform(0.35, 0.8)).normalized()
        length = rng.uniform(0.26, 0.38)
        spin = rng.uniform(0, math.tau)
        fan(bm, ring(bm, base, d, 0.02, 3, spin), base + d * length, FOLIAGE)
        sheath = ring(bm, base + d * length * 0.6, d, 0.024, 3, spin + math.pi / 3)
        fan(bm, sheath, base + d * length * 0.35, BLOSSOM)
        fan(bm, sheath, base + d * length * 0.92, BLOSSOM)


def sunflower(bm, rng):
    """One tall stem curving to a nodding head: brown disc, ring of yellow rays, green back; big leaves up the stem.
    The head faces -Y in Blender, i.e. +Z (glTF/Godot forward-facing-the-viewer) after export."""
    path = [Vector((0, 0, -0.03)), Vector((0.01, -0.01, 0.5)), Vector((0.0, -0.03, 1.0)), Vector((0.01, -0.08, 1.44))]
    stem(bm, path, 0.016, 0.01, sides=4)
    axis = Vector((0.15, -1, -0.35)).normalized()
    centre = path[-1] + axis * 0.06
    a, b = basis(axis)
    rim = ring(bm, centre, axis, 0.1, 12)
    fan(bm, rim, centre + axis * 0.025, HEART)
    fan(bm, rim, path[-1], FOLIAGE)
    for i in range(12):
        ta = (i + 0.5) * math.tau / 12
        tipv = bm.verts.new(centre + (a * math.cos(ta) + b * math.sin(ta)) * 0.2 + axis * 0.012)
        face(bm, (rim[i], rim[(i + 1) % 12], tipv), BLOSSOM)
    for i, z in enumerate((0.3, 0.55, 0.8, 1.05)):
        seg = min(int(z / 0.5), 2)
        p = path[seg].lerp(path[seg + 1], (z - path[seg].z) / (path[seg + 1].z - path[seg].z))
        leaf(bm, p, i * 2.4 + rng.uniform(-0.3, 0.3), 0.3 - 0.03 * i, 0.1, 0.7, 0.9, segs=3, fold=0.3, peak=0.35)


# name -> (builder, seed, [foliage, blossom, (heart)] palette names, flowers.json entry minus name/file/height)
PLANTS = {
    "snowdrop": (snowdrop, 1, ["leaf_deep", "snow", "leaf_light"], dict(
        bloom=["winter"], habitat="near_water", colour="white drooping bells with a green heart",
        real_plant="snowdrop (Galanthus nivalis)")),
    "tulip": (tulip, 2, ["leaf", "terracotta"], dict(
        bloom=["spring"], habitat="plain", colour="warm red closed cups",
        real_plant="garden tulip (Tulipa gesneriana)")),
    "poppy": (poppy, 3, ["leaf", "terracotta", "ink"], dict(
        bloom=["summer"], habitat="any", colour="warm red four-petalled cups with a dark centre",
        real_plant="corn poppy (Papaver rhoeas)")),
    "heather": (heather, 4, ["leaf_deep", "rose"], dict(
        bloom=["summer", "autumn"], habitat="hills", colour="rose-pink flower spikes on a dark green mound",
        real_plant="common heather (Calluna vulgaris)")),
    "sunflower": (sunflower, 5, ["leaf", "gold", "bark"], dict(
        bloom=["summer", "autumn"], habitat="plain", colour="golden yellow rays around a brown disc",
        real_plant="sunflower (Helianthus annuus)")),
}


def build(name, fn, seed, colours):
    rng = random.Random(seed)
    bm = bmesh.new()
    fn(bm, rng)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Face order out of bmesh ops varies between runs and the exporter keeps it as triangle order:
    # triangulate and sort by position so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    tris = len(bm.faces)
    used = sorted({f.material_index for f in bm.faces})
    assert tris <= MAX_TRIS, f"{name}: {tris} triangles, budget is {MAX_TRIS}"
    assert used == list(range(len(colours))), f"{name}: slots used {used}, expected 0..{len(colours) - 1}"
    bake_shade(bm, 0.15, strength=0.35, base=0.7)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    height = max(v.co.z for v in bm.verts)
    print(f"{name}: {tris} triangles, {height:.2f} m tall")
    bm.free()
    for slot, colour in zip(("foliage", "blossom", "heart"), colours):
        mesh.materials.append(material(f"{name}_{slot}", colour))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))
    return height


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
entries = []
for name, (fn, seed, colours, info) in PLANTS.items():
    height = build(name, fn, seed, colours)
    entries.append({"name": name, "file": name + ".glb", "bloom": info["bloom"], "habitat": info["habitat"],
                    "height_m": round(height, 2), "colour": info["colour"], "real_plant": info["real_plant"]})
for season in ("winter", "spring", "summer", "autumn"):
    assert any(season in e["bloom"] for e in entries), f"nothing blooms in {season}"
with open(os.path.join(OUT, "flowers.json"), "w") as f:
    json.dump(entries, f, indent=2)
    f.write("\n")
