"""Generate low-poly bush models (3 variants each of hazel, holly, bramble) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_bushes.py
Then: godot --headless --path . --import

Writes assets/bushes/<kind>_<n>.glb, built like the trees (tools/make_trees.py, whose helpers it reuses):
one mesh, surface 0 = wood, surface 1 = leaves (tinted per season), base at the origin, seeded.
"""
import math
import os
import random
import sys

from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_trees import bpy, clump, lerp_radii, tube, wander_path, build  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "bushes")


def hazel(bm, rng, p):
    """Thin stems fanning out from one root, each topped with a leafy clump: a loose rounded vase."""
    n = p["stems"]
    for i in range(n):
        ang = math.tau * i / n + rng.uniform(-0.4, 0.4)
        side = Vector((math.cos(ang), math.sin(ang), 0))
        stem = wander_path(side * 0.1, side * p["spread"] + Vector((0, 0, 1)), rng.uniform(*p["length"]), 3, 0.12, rng)
        tube(bm, stem, lerp_radii(0.045, 0.02, 4), 4, bumpy=0.0, seed=30 + i)
        r = rng.uniform(*p["leaf"])  # tall clump hanging down the stem's top half
        clump(bm, stem[-1] - Vector((0, 0, r * 0.5)), r, p["squash"], rng, 6)
    for offset, radius in p["top"]:
        clump(bm, Vector(offset), radius, p["squash"], rng, 6)


def holly(bm, rng, p):
    """Stubby trunk under dense clumps stacked in narrowing tiers: a compact evergreen cone."""
    tube(bm, [Vector((0, 0, 0)), Vector((0, 0, p["z0"]))], [0.07, 0.05], 4, bumpy=0.0, seed=40)
    z, r = p["z0"], p["radius"]
    for count in p["tiers"]:
        spin = rng.uniform(0, math.tau)
        for j in range(count):
            ang = spin + math.tau * j / count
            off = Vector((math.cos(ang), math.sin(ang), 0)) * r * (0.55 if count > 1 else 0.0)
            clump(bm, Vector((0, 0, z)) + off, r * rng.uniform(0.8, 1.0), p["squash"], rng, 7)
        z += r * p["step"]
        r *= p["shrink"]


def bramble(bm, rng, p):
    """Canes arching out and back down to the ground around low flattened leaf mounds: a sprawling thicket."""
    n = p["canes"]
    for i in range(n):
        ang = math.tau * i / n + rng.uniform(-0.3, 0.3)
        side = Vector((math.cos(ang), math.sin(ang), 0))
        reach = rng.uniform(*p["reach"])
        arc = [side * reach * t + Vector((0, 0, p["arch"] * math.sin(math.pi * t))) for t in (0.0, 0.3, 0.6, 1.0)]
        tube(bm, arc, lerp_radii(0.03, 0.015, 4), 3, bumpy=0.0, seed=50 + i)
        if i < p["leafy"]:  # leaves along the cane's crest, the bare tip arching out of them
            clump(bm, (arc[1] + arc[2]) / 2, rng.uniform(0.35, 0.45), p["squash"], rng, 6)
    for offset, radius in p["mounds"]:
        clump(bm, Vector(offset), radius, p["squash"], rng, 7)


# kind -> (builder, wood, leaves (palette names), [variant params]). Comments say what sets each variant apart.
KINDS = {
    "hazel": (hazel, "bark", "leaf", [
        # tall vase: 5 long stems, open top
        dict(stems=5, spread=0.35, length=(1.7, 2.0), leaf=(0.45, 0.55), squash=1.5, top=[((0, 0, 1.0), 0.6)]),
        # round: 4 shorter stems, full middle
        dict(stems=4, spread=0.5, length=(1.2, 1.5), leaf=(0.5, 0.6), squash=1.2, top=[((0, 0, 0.8), 0.7)]),
        # wide: 6 splayed stems, flat crown
        dict(stems=6, spread=0.8, length=(1.3, 1.6), leaf=(0.45, 0.5), squash=1.1, top=[]),
    ]),
    "holly": (holly, "bark", "leaf_deep", [
        # cone: 3 + 2 + 1 clumps
        dict(z0=0.35, radius=0.5, tiers=(3, 2, 1), step=0.85, shrink=0.75, squash=1.0),
        # tall column: 2 + 2 + 1 + 1
        dict(z0=0.3, radius=0.42, tiers=(2, 2, 1, 1), step=0.95, shrink=0.85, squash=1.15),
        # low dome: 4 wide + 1
        dict(z0=0.25, radius=0.45, tiers=(4, 1), step=0.7, shrink=0.9, squash=0.8),
    ]),
    "bramble": (bramble, "bark", "leaf", [
        # round mound
        dict(canes=5, reach=(1.0, 1.3), arch=0.45, leafy=4, squash=0.6,
             mounds=[((0, 0, 0.3), 0.7), ((0.5, 0.2, 0.2), 0.5)]),
        # long sprawl: canes reach far, mounds in a row
        dict(canes=6, reach=(1.2, 1.5), arch=0.4, leafy=4, squash=0.55,
             mounds=[((-0.45, 0, 0.25), 0.55), ((0.45, 0.1, 0.25), 0.6)]),
        # tall tangle: high arches over one big mound
        dict(canes=4, reach=(0.9, 1.1), arch=0.7, leafy=3, squash=0.7,
             mounds=[((0, 0, 0.4), 0.75)]),
    ]),
}


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
for k, (kind, (fn, wood, leaves, variants)) in enumerate(KINDS.items()):
    for i, params in enumerate(variants):
        build(f"{kind}_{i}", fn, params, 100 + 10 * k + i, wood, leaves, OUT)
