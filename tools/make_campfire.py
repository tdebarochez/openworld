"""Generate three forest campfires as .glb files for Godot, each a fire in a ring of stones with a
little camp round it: campfire_0 a teepee fire, two log seats (a blanket folded on one), a woodpile
and an axe in its chopping block; campfire_1 a star fire (four logs pushed in as they burn), a long
log seat and two stumps, a kettle warming on a flat stone, a bedroll and a few split logs;
campfire_2 a teepee fire under a stick tripod with a hanging pot, three stumps in a half circle, a
woodpile and a bedroll.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_campfire.py
Then: godot --headless --path . --import

Same conventions as tools/make_landmarks.py (whose helpers they reuse): origin at the fire's centre on
the ground, Godot +Z = Blender -Y, things sunk a little for uneven ground, flat-shaded, baked shading
(make_trees.bake_shade). Material slots: stone, wood (bark), cut (end grain), ash, ember (campfires.gd
makes it glow), metal, cloth. Nothing is above ~1.6 m and nothing reaches farther than 2.2 m from the
fire, so campfires.gd's CLEAR leaves open ground round the camp. The flames,
sparks and smoke are drawn by campfires.gd's shaders, not here. Seeded, so re-running gives the same files.
"""
import os
import random
import sys
from math import cos, pi, sin

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_cabins import stick  # noqa: E402
from make_houses import Z, box, material  # noqa: E402
from make_landmarks import frustum, lump  # noqa: E402
from make_rocks import stone  # noqa: E402
from make_trees import bake_shade, export  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "campfires")
STONE, WOOD, CUT, ASH, EMBER, METAL, CLOTH = range(7)  # stone first: make_rocks.stone leaves faces at 0
SLOTS = ("stone", "wood", "cut", "ash", "ember", "metal", "cloth")


def log(bm, a, b, r, n=6, phase=0.0, side=WOOD, ends=CUT):
    """n-sided log from a to b: bark round it, end grain on both cuts."""
    a, b = Vector(a), Vector(b)
    u = (b - a).normalized()
    s = (u.cross(Z) if abs(u.z) < 0.95 else Vector((1, 0, 0))).normalized()
    t = u.cross(s)
    ra = [bm.verts.new(a + (s * cos(phase + 2 * pi * i / n) + t * sin(phase + 2 * pi * i / n)) * r) for i in range(n)]
    rb = [bm.verts.new(v.co + (b - a)) for v in ra]
    bm.faces.new(ra[::-1]).material_index = ends
    bm.faces.new(rb).material_index = ends
    for i in range(n):
        bm.faces.new([ra[i - 1], ra[i], rb[i], rb[i - 1]]).material_index = side


def stump(bm, x, y, h, r=0.22):
    """Seat or chopping block: a short upright log sunk 0.15 m, its cut on top."""
    log(bm, (x, y, -0.15), (x, y, h), r, n=7, phase=x + y)


def hearth(bm, rng, stones, r=0.6):
    """The fire's bed: a ring of `stones` stones, grey ash inside and a heap of glowing embers."""
    for i in range(stones):
        a = 2 * pi * i / stones + rng.uniform(-0.12, 0.12)
        s = rng.uniform(0.85, 1.15)
        stone(bm, rng, (0.16 * s, 0.12 * s, 0.12 * s), 14, centre=(r * cos(a), r * sin(a), 0.06), rot=(0, 0, a),
              jitter=0.15, cuts=[((0, 0, 1), 0.7)])
    frustum(bm, (0, 0), r - 0.08, r - 0.14, -0.05, 0.03, ASH, n=10)
    for i in range(9):
        a = i * 2.4 + rng.uniform(-0.3, 0.3)
        d = 0.08 + 0.3 * (i / 9) ** 0.7
        lump(bm, (d * cos(a), d * sin(a), 0.04), rng.uniform(0.06, 0.1), EMBER, h=rng.uniform(0.04, 0.07))


def teepee(bm, rng, sticks=6, r=0.42, top=0.62):
    """Sticks leaning together over the embers, charred at their feet."""
    for i in range(sticks):
        a = 2 * pi * i / sticks + rng.uniform(-0.2, 0.2)
        foot = Vector((r * cos(a), r * sin(a), 0.02))
        head = Vector((0.05 * cos(a + 2.0), 0.05 * sin(a + 2.0), top + rng.uniform(-0.06, 0.06)))
        log(bm, foot, foot.lerp(head, 0.35), 0.045, n=5, side=ASH, ends=ASH)
        log(bm, foot.lerp(head, 0.35), head, 0.04, n=5, ends=ASH)


def woodpile(bm, x, y, angle, rows=(4, 3, 2), length=0.6, r=0.08):
    """Split logs stacked in a pyramid, lying across `angle` (their cuts show both ways)."""
    d = Vector((cos(angle), sin(angle), 0))
    n = d.cross(Z)
    for k, count in enumerate(rows):
        for i in range(count):
            c = Vector((x, y, r * 0.9 + k * r * 1.75)) + d * ((i - (count - 1) / 2) * r * 2.05)
            log(bm, c - n * length / 2, c + n * length / 2, r, n=5, phase=0.4 * i + k)


def axe(bm, x, y, top):
    """Axe struck into the top of a chopping block at (x, y), handle up and out."""
    head = Vector((x + 0.02, y, top + 0.04))
    end = head + Vector((0.45, -0.12, 0.42))
    stick(bm, head, end, 0.035, 0.03, WOOD)
    box(bm, (x - 0.1, y - 0.015, top - 0.04), (x + 0.07, y + 0.015, top + 0.08), METAL)


def bedroll(bm, a, b, colour=CLOTH):
    """Rolled blanket lying from a to b, tied with two straps."""
    a, b = Vector(a), Vector(b)
    log(bm, a, b, 0.12, n=8, side=colour, ends=colour)
    for t in (0.22, 0.78):
        c = a.lerp(b, t)
        u = (b - a).normalized() * 0.025
        log(bm, c - u, c + u, 0.128, n=8, side=METAL, ends=METAL)


def camp_teepee(bm):
    """campfire_0: teepee fire; a long log seat behind (blanket folded on it), a shorter one to the left,
    a woodpile to the right and an axe in its block in front."""
    rng = random.Random(41)
    hearth(bm, rng, 11)
    teepee(bm, rng)
    log(bm, (-0.8, 1.6, 0.13), (0.75, 1.68, 0.13), 0.17, n=7)
    log(bm, (-1.55, 0.6, 0.12), (-1.62, -0.65, 0.12), 0.16, n=7, phase=0.3)
    box(bm, (-0.55, 1.47, 0.28), (-0.12, 1.8, 0.33), CLOTH)  # folded blanket on the seat
    box(bm, (-0.52, 1.47, 0.33), (-0.15, 1.8, 0.36), CLOTH)
    woodpile(bm, 1.55, 0.75, 1.35)
    stump(bm, 1.2, -1.1, 0.32, r=0.2)
    axe(bm, 1.2, -1.1, 0.32)
    for i in range(3):  # chips round the block
        a = i * 2.1
        box(bm, (1.2 + 0.32 * cos(a) - 0.04, -1.1 + 0.32 * sin(a) - 0.025, 0), (1.2 + 0.32 * cos(a) + 0.04, -1.1 + 0.32 * sin(a) + 0.025, 0.02), CUT)


def camp_star(bm):
    """campfire_1: star fire, four logs pushed in end-first over the ring; a long log seat behind, two
    stumps in front, a kettle warming on a flat stone, a bedroll and a few split logs."""
    rng = random.Random(42)
    hearth(bm, rng, 10, r=0.58)
    for i in range(4):
        a = pi / 4 + i * pi / 2 + rng.uniform(-0.15, 0.15)
        log(bm, (1.25 * cos(a), 1.25 * sin(a), 0.07), (0.12 * cos(a), 0.12 * sin(a), 0.12), 0.07, n=6, ends=ASH)
    log(bm, (-0.95, 1.72, 0.14), (0.95, 1.62, 0.14), 0.18, n=7)
    stump(bm, -1.35, -0.85, 0.42)
    stump(bm, 1.4, -0.7, 0.38, r=0.2)
    stone(bm, rng, (0.24, 0.2, 0.08), 14, centre=(0.9, 0.0, 0.03), jitter=0.1, cuts=[((0, 0, 1), 0.5)])
    frustum(bm, (0.9, 0.0), 0.12, 0.09, 0.07, 0.25, METAL, n=8)  # kettle: body, lid, spout, handle
    frustum(bm, (0.9, 0.0), 0.08, 0.03, 0.25, 0.29, METAL, n=8)
    stick(bm, (0.79, 0.0, 0.14), (0.7, 0.0, 0.24), 0.025, 0.025, METAL)
    for a, b in (((0.97, -0.08, 0.25), (0.97, -0.08, 0.36)), ((0.97, -0.08, 0.36), (0.83, 0.08, 0.36)),
                 ((0.83, 0.08, 0.36), (0.83, 0.08, 0.25))):
        stick(bm, a, b, 0.015, 0.015, METAL)
    bedroll(bm, (-1.72, 0.5, 0.11), (-1.6, -0.25, 0.11))
    for i, (x, y, a) in enumerate(((1.45, 1.05, 0.3), (1.62, 0.8, 1.1), (1.35, 0.78, -0.4))):
        d = Vector((cos(a), sin(a), 0)) * 0.27
        log(bm, Vector((x, y, 0.06 + 0.1 * (i == 2))) - d, Vector((x, y, 0.06 + 0.1 * (i == 2))) + d, 0.07, n=5, phase=i)


def camp_tripod(bm):
    """campfire_2: teepee fire under a tripod of poles with a pot hanging from it; three stumps in a half
    circle behind, a woodpile and a bedroll in front."""
    rng = random.Random(43)
    hearth(bm, rng, 12, r=0.62)
    teepee(bm, rng, sticks=5, r=0.38, top=0.55)
    apex = Vector((0, 0, 1.5))
    for i in range(3):
        a = pi / 2 + 2 * pi * i / 3
        foot = Vector((0.9 * cos(a), 0.9 * sin(a), -0.1))
        stick(bm, foot, apex + (apex - foot).normalized() * 0.12, 0.05, 0.05, WOOD)
    stick(bm, apex, (0, 0, 1.08), 0.012, 0.012, METAL)  # the chain
    frustum(bm, (0, 0), 0.13, 0.16, 0.86, 1.06, METAL, n=8)  # pot, rim, bail
    frustum(bm, (0, 0), 0.17, 0.17, 1.03, 1.06, METAL, n=8)
    for a, b in (((-0.16, 0, 1.04), (0, 0, 1.12)), ((0, 0, 1.12), (0.16, 0, 1.04))):
        stick(bm, a, b, 0.012, 0.012, METAL)
    for k in range(3):
        a = pi / 2 + (k - 1) * 0.85
        stump(bm, 1.6 * cos(a), 1.6 * sin(a), 0.4 - 0.04 * k)
    woodpile(bm, -1.5, -0.6, 0.4, rows=(3, 2, 1))
    bedroll(bm, (1.2, -1.05, 0.11), (1.75, -0.45, 0.11))


def build(name, fn, palette):
    bm = bmesh.new()
    fn(bm)
    assert {f.material_index for f in bm.faces} == set(range(len(SLOTS))), name + ": empty material slot"
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Same as make_houses.build: triangulate and sort so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    for f in bm.faces:
        f.smooth = False
    bake_shade(bm, 0.8, strength=0.5, base=0.8)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    xs, ys, zs = ([v.co[i] for v in bm.verts] for i in range(3))
    reach = max(Vector((x, y)).length for x, y in zip(xs, ys))
    print(f"{name}: {len(bm.faces)} triangles, reach {reach:.2f} m, z {min(zs):.2f}..{max(zs):.2f} m")
    bm.free()
    for i, slot in enumerate(SLOTS):
        mesh.materials.append(material(f"{name}_{slot}", palette[i], 0.5 if slot == "metal" else 0.9))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))


if __name__ == "__main__":
    bpy.ops.wm.read_factory_settings(use_empty=True)
    os.makedirs(OUT, exist_ok=True)
    build("campfire_0", camp_teepee, ["stone", "bark", "sand", "soot", "ember", "ink", "terracotta"])
    build("campfire_1", camp_star, ["stone", "bark", "sand", "soot", "ember", "ink", "leaf_deep"])
    build("campfire_2", camp_tripod, ["stone", "bark", "sand", "soot", "ember", "ink", "gold"])
