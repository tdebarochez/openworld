"""Generate the landmarks seen from afar and the village-square features as .glb files for Godot:
tower (ruined round keep with a broken top, a breach, a wall stub and fallen blocks), windmill (white
tower mill with a conical cap and a tail pole) and windmill_sails (the four sails, turned by world.gd's
shader), bridge (three-arch stone bridge with parapets and cutwaters), chapel (Romanesque chapel with
an apse and a bell-cote on its front gable), stones (a ring of standing stones and an outlier); well,
fountain and stall_0..2 (market stalls, three awning colours) for the village squares.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_landmarks.py
Then: godot --headless --path . --import

Same conventions as tools/make_houses.py (whose helpers they reuse): origin at the footprint centre on
the ground, the front (door, sails, counter) on -Y in Blender (+Z in Godot), foundations going down for
uneven ground, flat-shaded, baked shading (make_trees.bake_shade). Slot 1 is a roof on the chapel,
windmill and well (seasons.gd snows on it). The bridge runs along X (Godot X) from -BRIDGE_END to
+BRIDGE_END, origin at mid-span on its foot level; its piers go down to -4 m. The sails' origin is the
hub, their axis Blender -Y (Godot +Z); world.gd places them at WINDMILL_HUB in the windmill's frame.
world.gd collides with every model but the sails as trimeshes. Seeded, so re-running gives the same files.
"""
import os
import random
import sys
from math import cos, pi, sin, sqrt

import bmesh
import bpy
from mathutils import Euler, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_cabins import stick  # noqa: E402
from make_houses import (Z, arched_door, box, cone, gable, material, para, prism, quoins, ring, roof,  # noqa: E402
                         sides, turn)
from make_rocks import stone  # noqa: E402
from make_trees import bake_shade, export  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "landmarks")
WINDMILL_HUB = (0.0, -3.2, 8.3)  # Blender; world.gd WINDMILL_HUB = Vector3(0, 8.3, 3.2)
BRIDGE_END = 14.8  # m from mid-span to the end of each ramp


# --- Shared bits ----------------------------------------------------------------------------------

def frustum(bm, c, r0, r1, z0, z1, mat, n=12, phase=0.0):
    """Closed n-sided frustum from radius r0 at z0 to r1 at z1 around (c.x, c.y)."""
    a = [bm.verts.new((c[0] + r0 * cos(phase + 2 * pi * i / n), c[1] + r0 * sin(phase + 2 * pi * i / n), z0)) for i in range(n)]
    b = [bm.verts.new((c[0] + r1 * cos(phase + 2 * pi * i / n), c[1] + r1 * sin(phase + 2 * pi * i / n), z1)) for i in range(n)]
    for f in [a[::-1], b] + [[a[i - 1], a[i], b[i], b[i - 1]] for i in range(n)]:
        bm.faces.new(f).material_index = mat


def arc_block(bm, r0, r1, a0, a1, z0, z1, mat):
    """Wall piece of a round tower: between radii r0 and r1, angles a0 and a1, heights z0 and z1."""
    pts = [Vector((r * cos(a), r * sin(a), z0)) for r, a in ((r0, a0), (r1, a0), (r1, a1), (r0, a1))]
    prism(bm, pts, Vector((0, 0, z1 - z0)), mat)


def block(bm, c, size, rot, mat):
    """Box of `size` centred on `c`, turned by Euler angles `rot` (fallen stones, crates)."""
    m = Euler(rot).to_matrix()
    para(bm, c, m @ Vector((size[0], 0, 0)), m @ Vector((0, size[1], 0)), m @ Vector((0, 0, size[2])), mat)


def lump(bm, c, r, mat, h=None):
    """Six-sided bipyramid: a low-poly fruit, cabbage or cheese."""
    h = h or r
    mid = [bm.verts.new(p) for p in ring(c, r, 6)]
    top, bot = bm.verts.new(Vector(c) + Z * h), bm.verts.new(Vector(c) - Z * h * 0.7)
    for i in range(6):
        bm.faces.new([mid[i - 1], mid[i], top]).material_index = mat
        bm.faces.new([mid[i], mid[i - 1], bot]).material_index = mat


# --- Ruined tower ---------------------------------------------------------------------------------

def tower(bm):
    """Round keep 6.8 m across, broken off at 6 to 15.5 m: tall on its back, a breach down to 2 m on
    its left, arrow slits, a string course where the wall still reaches it, ivy, a crenel pair left on
    the highest stretch, a curtain-wall stub stepping down and fallen blocks at its foot. The foot and
    the stub go 3 m down: it stands on hilltops."""
    STONE, DARK, IVY, HOLE = range(4)
    rng = random.Random(41)
    ro, ri, n = 3.4, 2.5, 32
    frustum(bm, (0, 0), 4.1, 3.6, -3.0, 0.25, STONE, n=16)  # battered foot and inner floor
    door = -pi / 2  # front (-Y)
    tall = pi / 2 + 0.4
    breach = pi + 0.35
    tops = []
    for i in range(n):
        a = 2 * pi * (i + 0.5) / n
        d_tall = abs((a - tall + pi) % (2 * pi) - pi)
        d_breach = abs((a - breach + pi) % (2 * pi) - pi)
        h = 6.0 + 9.5 * (0.5 + 0.5 * cos(d_tall)) ** 1.5 + rng.uniform(-0.6, 0.6)
        if d_breach < 0.55:
            h = min(h, 2.0 + 6.0 * (d_breach / 0.55) ** 2 + rng.uniform(0, 0.4))
        tops.append(h)
    for i in range(n):
        a0, a1 = 2 * pi * i / n, 2 * pi * (i + 1) / n
        am = (a0 + a1) / 2
        z0 = 2.5 if abs((am - door + pi) % (2 * pi) - pi) < 0.2 else 0.25  # doorway, 1.3 m wide
        # Broken top in two steps per piece, so the edge reads as fallen courses, not a sawtooth.
        arc_block(bm, ri, ro, a0, am, z0, tops[i], STONE)
        arc_block(bm, ri, ro, am, a1, z0, tops[i] - rng.uniform(0.2, 0.7), STONE)
        if tops[i] > 5.4:  # string course
            arc_block(bm, ro - 0.05, ro + 0.14, a0, a1, 4.9, 5.15, DARK)
        if i % 5 == 2 and tops[i] > 4.0 and z0 < 1:  # arrow slits, dark and deep
            for zs in (1.6, 6.8, 10.5):
                if zs + 1.4 < tops[i] - 0.4:
                    arc_block(bm, ro - 0.1, ro + 0.02, am - 0.025, am + 0.025, zs, zs + 1.1, HOLE)
        if z0 > 1:  # lintel stones over the doorway
            arc_block(bm, ro - 0.05, ro + 0.1, a0, a1, 2.5, 2.85, DARK)
    for i in (round((tall / (2 * pi)) * n) - 1, round((tall / (2 * pi)) * n) + 2):  # crenels
        a0, a1 = 2 * pi * i / n, 2 * pi * (i + 1.4) / n
        arc_block(bm, ri + 0.15, ro, a0, a1, tops[i] - 0.3, tops[i] + 1.0, STONE)
    # Ivy creeping up the front-left and the back, slightly proud of the wall.
    for c, spread, up in ((-pi / 2 - 0.9, 0.7, 6.5), (pi / 2 + 0.9, 0.5, 9.0), (0.3, 0.35, 3.5)):
        k = 7
        for j in range(k):
            a0 = c - spread + 2 * spread * j / k
            a1 = a0 + 2 * spread / k
            h = up * (1 - abs(j - k / 2 + 0.5) / (k / 2 + 0.5)) * rng.uniform(0.7, 1.0)
            arc_block(bm, ro - 0.02, ro + 0.07, a0, a1, 0.1, max(0.6, h), IVY)
    # Curtain-wall stub running off to the right, stepping down (foundations deep: hilltops fall away).
    for x0, x1, h in ((3.0, 4.8, 4.2), (4.8, 6.2, 2.8), (6.2, 7.2, 1.4)):
        box(bm, (x0, -0.45, -3.0), (x1, 0.45, h + rng.uniform(-0.2, 0.2)), STONE)
    box(bm, (3.0, -0.5, 3.4), (4.8, 0.5, 3.6), DARK)
    # Fallen blocks half sunk at the foot of the breach; world.gd scatters rocks further out, on the ground.
    for k in range(12):
        a = breach + rng.uniform(-0.9, 0.9)
        r = rng.uniform(4.2, 5.4)
        s = rng.uniform(0.45, 0.9)
        block(bm, (r * cos(a), r * sin(a), 0.0), (s * rng.uniform(1.0, 1.6), s, s * 0.75),
              (rng.uniform(-0.4, 0.4), rng.uniform(-0.4, 0.4), rng.uniform(0, pi)), DARK if k % 3 == 0 else STONE)


# --- Windmill -------------------------------------------------------------------------------------

def windmill(bm):
    """Whitewashed tower mill: stone foot, tapering tower to 7.4 m, wooden curb and a shingled conical
    cap to 10.6 m with a knob, the windshaft coming out of it to the front, a door on the right side,
    small windows, the tail pole running down the back to a stone, millstones and sacks by the door."""
    WALL, ROOF, WOOD, GLASS, STONE = range(5)
    frustum(bm, (0, 0), 3.0, 2.85, -1.5, 0.4, STONE)
    frustum(bm, (0, 0), 2.75, 2.2, 0.4, 7.4, WALL)
    frustum(bm, (0, 0), 2.45, 2.45, 7.35, 7.65, WOOD)
    frustum(bm, (0, 0), 2.6, 0.18, 7.65, 10.45, ROOF)
    for k in range(4):  # shingle courses on the cap, lower edges proud
        z0 = 7.65 + k * 0.62
        r0 = 2.6 - (z0 - 7.65) / 2.8 * 2.42
        r1 = 2.6 - (z0 + 0.3 - 7.65) / 2.8 * 2.42
        frustum(bm, (0, 0), r0 + 0.06, r1 + 0.03, z0, z0 + 0.3, ROOF)
    cone(bm, (0, 0, 10.4), 0.22, 0.45, WOOD, n=6)

    def radius(z):
        return 2.75 - 0.55 * (z - 0.4) / 7.0

    def on_wall(a, z, w, h, depth, out, mat):
        d, t = Vector((cos(a), sin(a), 0)), Vector((-sin(a), cos(a), 0))
        para(bm, d * (radius(z + h / 2) + out) + Z * (z + h / 2), d * depth, t * w, Z * h, mat)
    on_wall(0.0, 0.4, 1.0, 1.95, 0.24, 0.0, WOOD)  # door (+X, the right-hand side)
    on_wall(0.0, 2.35, 1.3, 0.3, 0.36, 0.0, STONE)  # lintel
    for x in (-0.6, 0.6):  # jambs
        d = Vector((1, 0, 0))
        para(bm, d * (radius(1.4) + 0.02) + Vector((0, x, 1.35)), d * 0.3, Vector((0, 0.18, 0)), Z * 1.9, STONE)
    box(bm, (2.5, -0.7, -0.3), (3.3, 0.7, 0.32), STONE)  # step
    for a, z in ((pi * 0.25, 3.2), (pi * 0.95, 1.6), (pi * 1.25, 4.6), (pi * 1.75, 2.8), (pi * 0.6, 5.6), (-pi * 0.5, 5.4)):
        on_wall(a, z, 0.5, 0.6, 0.22, 0.0, GLASS)
        on_wall(a, z - 0.12, 0.66, 0.12, 0.3, 0.0, STONE)
    # Windshaft out of the cap's front to the hub, braced by a bearing block.
    hx, hy, hz = WINDMILL_HUB
    prism(bm, [Vector((0.24 * cos(2 * pi * i / 8), -1.5, hz + 0.24 * sin(2 * pi * i / 8))) for i in range(8)],
          Vector((0, hy + 0.2 + 1.5, 0)), WOOD)
    box(bm, (-0.45, -2.35, hz - 0.5), (0.45, -1.7, hz - 0.2), WOOD)
    # Tail pole down the back to a stone, with its two struts to the cap.
    stick(bm, (0, 2.0, 7.7), (0, 6.1, 0.7), 0.2, 0.2, WOOD)
    for x in (-1.0, 1.0):
        stick(bm, (x, 1.6, 7.55), (0, 4.4, 3.3), 0.1, 0.1, WOOD)
    box(bm, (-0.5, 5.8, -0.3), (0.5, 6.6, 0.55), STONE)
    # Millstones leaning by the door, sacks.
    frustum(bm, (3.7, 1.4), 0.7, 0.66, 0.0, 0.26, STONE, n=10)
    frustum(bm, (3.75, 1.45), 0.6, 0.56, 0.26, 0.5, STONE, n=10)
    for c, rz in (((3.3, -1.35, 0.3), 0.3), ((3.85, -1.0, 0.27), -0.4), ((3.55, -1.25, 0.75), 0.1)):
        block(bm, c, (0.62, 0.42, 0.55), (0, 0, rz), WALL)


def windmill_sails(bm):
    """Four lattice sails on stocks (an X), radius 6.3 m, two clothed, two bare; hub boss on the axle.
    Origin at the hub, sails in the XZ plane, axle along Y."""
    WOOD, CLOTH = range(2)
    prism(bm, [Vector((0.36 * cos(2 * pi * i / 8), -0.35, 0.36 * sin(2 * pi * i / 8))) for i in range(8)],
          Vector((0, 0.6, 0)), WOOD)
    X = Vector((1, 0, 0))
    Y = Vector((0, 1, 0))
    for k in range(4):
        a = pi / 4 + k * pi / 2
        d = X * cos(a) + Z * sin(a)
        t = X * -sin(a) + Z * cos(a)
        para(bm, d * 3.2 + Y * -0.12, d * 6.4, t * 0.2, Y * 0.18, WOOD)  # stock
        r0, r1, w = 1.4, 6.2, 1.25
        for e in (0.08, w):  # rails along the sail
            para(bm, d * ((r0 + r1) / 2) + t * e + Y * -0.2, d * (r1 - r0), t * 0.07, Y * 0.07, WOOD)
        bars = 10
        for j in range(bars + 1):  # cross bars
            r = r0 + (r1 - r0) * j / bars
            para(bm, d * r + t * (w / 2) + Y * -0.2, d * 0.06, t * (w + 0.2), Y * 0.06, WOOD)
        if k % 2 == 0:  # cloth stretched behind the lattice
            para(bm, d * ((r0 + r1) / 2 + 0.05) + t * (w / 2 + 0.04) + Y * -0.13, d * (r1 - r0 - 0.2), t * (w - 0.1), Y * 0.03, CLOTH)
        else:  # furled cloth along the stock
            para(bm, d * ((r0 + r1) / 2) + t * 0.2 + Y * -0.15, d * (r1 - r0 - 0.4), t * 0.16, Y * 0.12, CLOTH)


# --- Bridge ---------------------------------------------------------------------------------------

def deck(s):
    """Top of the bridge deck s m from mid-span: a hump, then the ramps down past each end."""
    if abs(s) <= 13.0:
        return 0.6 + 2.5 * (1 - (s / 13.0) ** 2)
    return 0.6 - 0.8 * (abs(s) - 13.0) / (BRIDGE_END - 13.0)


ARCHES = ((0.0, 3.3, -0.9), (-7.2, 1.9, -0.6), (7.2, 1.9, -0.6))  # centre s, radius, centre z


def soffit(s):
    """Underside of the masonry at s: an arch's intrados, or the foundations (-4 m)."""
    for c, r, zc in ARCHES:
        if abs(s - c) < r:
            return max(zc + sqrt(r * r - (s - c) ** 2), -4.0)
    return -4.0


def bridge(bm):
    """Three-arch stone bridge 29.6 m long and 3.4 m wide: humped deck, parapets with a coping, arch
    rings of alternating stones, cutwaters on both piers, a string course and ivy."""
    STONE, TRIM, IVY = range(3)
    W = 3.4
    cuts = sorted({round(x * 0.5, 2) for x in range(-29, 30)} | {c + e for c, r, _ in ARCHES for e in (-r, r)}
                  | {-BRIDGE_END, BRIDGE_END, -13.0, 13.0})
    cuts = [s for s in cuts if abs(s) <= BRIDGE_END]
    for s0, s1 in zip(cuts, cuts[1:]):
        m = (s0 + s1) / 2
        b0, b1 = soffit(s0 + 1e-4 if s0 < m else s0), soffit(s1 - 1e-4)
        pts = [Vector((s0, -W / 2, b0)), Vector((s1, -W / 2, b1)), Vector((s1, -W / 2, deck(s1))), Vector((s0, -W / 2, deck(s0)))]
        prism(bm, pts, Vector((0, W, 0)), STONE)
        if abs(m) < 13.0:  # parapets and their coping
            for y0, y1 in ((-W / 2, -W / 2 + 0.32), (W / 2 - 0.32, W / 2)):
                prism(bm, [Vector((s0, y0, deck(s0))), Vector((s1, y0, deck(s1))), Vector((s1, y0, deck(s1) + 0.62)),
                           Vector((s0, y0, deck(s0) + 0.62))], Vector((0, y1 - y0, 0)), STONE)
                prism(bm, [Vector((s0, y0 - 0.05, deck(s0) + 0.62)), Vector((s1, y0 - 0.05, deck(s1) + 0.62)),
                           Vector((s1, y0 - 0.05, deck(s1) + 0.74)), Vector((s0, y0 - 0.05, deck(s0) + 0.74))],
                      Vector((0, y1 - y0 + 0.1, 0)), TRIM)
            for y0 in (-W / 2 - 0.06, W / 2):  # string course under the parapet
                prism(bm, [Vector((s0, y0, deck(s0) - 0.3)), Vector((s1, y0, deck(s1) - 0.3)), Vector((s1, y0, deck(s1) - 0.12)),
                           Vector((s0, y0, deck(s0) - 0.12))], Vector((0, 0.06, 0)), TRIM)
    for s in (-13.0, 13.0):  # end posts of the parapets
        for y in (-W / 2 + 0.16, W / 2 - 0.16):
            box(bm, (s - 0.25, y - 0.25, deck(s) - 0.2), (s + 0.25, y + 0.25, deck(s) + 0.95), TRIM)
    # Arch rings: voussoirs proud of both faces, alternately trim and stone, from the water up.
    for c, r, zc in ARCHES:
        a0 = -0.35 if r > 2 else -0.3
        n = 17 if r > 2 else 11
        for i in range(n):
            t0 = a0 + (pi - 2 * a0) * i / n
            t1 = a0 + (pi - 2 * a0) * (i + 1) / n
            q = [(r, t0), (r + 0.5, t0), (r + 0.5, t1), (r, t1)]
            for y0 in (-W / 2 - 0.05, W / 2 - 0.01):
                prism(bm, [Vector((c + rr * cos(t), y0, zc + rr * sin(t))) for rr, t in q], Vector((0, 0.06, 0)),
                      TRIM if i % 2 == 0 else STONE)
    # Cutwaters: pointed both ways on each pier, capped.
    for c in (-4.35, 4.35):
        for side in (-1, 1):
            y0 = side * W / 2
            pts = [Vector((c - 0.95, y0, -4.0)), Vector((c + 0.95, y0, -4.0)), Vector((c, y0 + side * 1.3, -4.0))]
            prism(bm, pts if side > 0 else pts[::-1], Vector((0, 0, 5.1)), STONE)
            apex = Vector((c, y0, 1.95))
            for a, b in ((pts[0], pts[2]), (pts[2], pts[1])):
                va, vb = bm.verts.new(a + Z * 5.1), bm.verts.new(b + Z * 5.1)
                bm.faces.new([va, vb, bm.verts.new(apex)]).material_index = TRIM
    # Ivy down the faces near the ends.
    rng = random.Random(9)
    for s0, y0 in ((-11.5, -W / 2 - 0.08), (9.6, W / 2 + 0.02), (10.6, -W / 2 - 0.08)):
        for j in range(5):
            s = s0 + j * 0.45
            top = deck(s) - 0.15
            prism(bm, [Vector((s, y0, top - rng.uniform(1.0, 2.6))), Vector((s + 0.45, y0, top - rng.uniform(1.0, 2.6))),
                       Vector((s + 0.45, y0, top)), Vector((s, y0, top))], Vector((0, 0.06, 0)), IVY)


# --- Chapel ---------------------------------------------------------------------------------------

def chapel(bm):
    """Small Romanesque chapel, nave 7.2 x 4.6 m: limestone walls with quoins and buttresses, tiled
    roof, a round apse with a half-cone roof at the back, an arched door under a round window, narrow
    arched windows, a bell-cote rising over the front gable with its bell, a cross on top, a bench.
    Built with the door to +X, then turned."""
    WALL, ROOF, WOOD, GLASS, STONE, BELL = range(6)
    L, S, h = 3.6, 2.3, 3.6
    box(bm, (-L - 0.15, -S - 0.15, -1.5), (L + 0.15, S + 0.15, 0.3), STONE)
    box(bm, (-L, -S, 0.3), (L, S, h), WALL)
    rise = roof(bm, -L, L, 2 * S, h, 36, 0.35, 0.25, 7)
    ws = sides(-L, L, -S, S)
    for wall in (ws[1], ws[3]):
        gable(bm, wall, h, rise, WALL)
    quoins(bm, ws, 0.3, h)
    arched_door(bm, ws[1], S, 1.2, 2.3, z=0.3)
    # Round window in the front gable, with a stone frame.
    rc = (S, h + 0.75)
    ws[1].prism(bm, [(rc[0] + 0.38 * cos(2 * pi * i / 12), rc[1] + 0.38 * sin(2 * pi * i / 12)) for i in range(12)], -0.1, 0.03, GLASS)
    for i in range(12):
        a0, a1 = 2 * pi * i / 12, 2 * pi * (i + 1) / 12
        ws[1].prism(bm, [(rc[0] + r * cos(a), rc[1] + r * sin(a)) for r, a in ((0.38, a0), (0.56, a0), (0.56, a1), (0.38, a1))],
                    0, 0.08, STONE)

    def lancet(w, s, z, width=0.42, height=1.2):
        r = width / 2
        pts = [(s - r, z), (s + r, z)] + [(s + r * cos(pi * i / 6), z + height - r + r * sin(pi * i / 6)) for i in range(7)]
        w.prism(bm, pts, -0.1, 0.03, GLASS)
        w.box(bm, s - r - 0.12, s + r + 0.12, z - 0.12, z, 0, 0.12, STONE)
    for wall in (ws[0], ws[2]):
        for s in (2.4, 4.8):
            lancet(wall, s, 1.5)
        for s in (0.05, 3.6, 7.15):  # buttresses
            wall.box(bm, s - 0.3, s + 0.3, -0.2, 2.3 if 0.5 < s < 7 else 1.6, 0, 0.5, STONE)
            wall.box(bm, s - 0.3, s + 0.3, 2.3 if 0.5 < s < 7 else 1.6, (2.3 if 0.5 < s < 7 else 1.6) + 0.15, 0, 0.62, ROOF)
    # Apse: half a 12-gon on the back wall, a lancet in its axis, a half-cone roof.
    half = [Vector((-L + 1.9 * cos(pi / 2 + pi * i / 6), 1.9 * sin(pi / 2 + pi * i / 6), 0)) for i in range(7)]
    prism(bm, [p + Z * -1.5 for p in half], Z * 4.6, WALL)
    prism(bm, [Vector((-L + 2.05 * cos(pi / 2 + pi * i / 6), 2.05 * sin(pi / 2 + pi * i / 6), -1.5)) for i in range(7)], Z * 1.8, STONE)
    eave = [bm.verts.new(Vector((-L + 2.15 * cos(pi / 2 + pi * i / 6), 2.15 * sin(pi / 2 + pi * i / 6), 3.05))) for i in range(7)]
    apex = bm.verts.new((-L + 0.05, 0, 4.45))
    for i in range(6):
        bm.faces.new([eave[i], eave[i + 1], apex]).material_index = ROOF
    bm.faces.new(eave[::-1]).material_index = ROOF
    bm.faces.new([eave[6], eave[0], apex]).material_index = ROOF
    box(bm, (-L - 1.95, -0.21, 1.6), (-L - 1.8, 0.21, 2.6), GLASS)
    # Bell-cote: piers up from the front wall, an arch, a gabled top and a cross; the bell hangs inside.
    x0, x1, top = L - 0.35, L + 0.15, h + rise + 2.2
    for y0, y1 in ((-1.0, -0.45), (0.45, 1.0)):
        box(bm, (x0, y0, h), (x1, y1, top), WALL)
    box(bm, (x0, -0.45, h), (x1, 0.45, h + rise + 0.3), WALL)  # sill of the opening, over the ridge
    for i in range(6):
        y0, y1 = -0.45 + 0.15 * i, -0.45 + 0.15 * (i + 1)
        za, zb = top - 1.05 + sqrt(max(0.0, 0.2025 - y0 * y0)), top - 1.05 + sqrt(max(0.0, 0.2025 - y1 * y1))
        prism(bm, [Vector((x0, y0, za)), Vector((x0, y1, zb)), Vector((x0, y1, top)), Vector((x0, y0, top))], Vector((x1 - x0, 0, 0)), WALL)
    box(bm, (x0 - 0.08, -1.1, top), (x1 + 0.08, 1.1, top + 0.12), STONE)
    prism(bm, [Vector((x0 - 0.1, -1.2, top + 0.12)), Vector((x0 - 0.1, 1.2, top + 0.12)), Vector((x0 - 0.1, 0, top + 0.6))],
          Vector((x1 - x0 + 0.2, 0, 0)), ROOF)
    box(bm, (x0 + 0.17, -0.06, top + 0.5), (x1 - 0.17, 0.06, top + 1.3), STONE)
    box(bm, (x0 + 0.17, -0.3, top + 0.95), (x1 - 0.17, 0.3, top + 1.07), STONE)
    box(bm, (x0 - 0.05, -0.5, top - 0.75), (x1 + 0.05, 0.5, top - 0.63), WOOD)  # yoke
    frustum(bm, ((x0 + x1) / 2, 0), 0.33, 0.17, top - 1.5, top - 0.92, BELL, n=10)
    frustum(bm, ((x0 + x1) / 2, 0), 0.17, 0.08, top - 0.92, top - 0.75, BELL, n=10)
    # A bench against the front wall, right of the door.
    for s in (3.55, 4.25):
        ws[1].box(bm, s - 0.06, s + 0.06, 0.3, 0.72, 0.08, 0.45, WOOD)
    ws[1].box(bm, 3.35, 4.45, 0.72, 0.78, 0.05, 0.5, WOOD)
    turn(bm, -pi / 2)


# --- Standing stones ------------------------------------------------------------------------------

def stones(bm):
    """Nine standing stones in a 5.5 m ring, one fallen, a flat stone in the middle and a tall outlier
    8.5 m out; each stone's foot 0.6 m underground. Moss on the upward facets."""
    rng = random.Random(23)

    def menhir(x, y, h, w, lean=(0.0, 0.0)):
        stone(bm, rng, (w, w * 0.75, h / 2 + 0.3), 22, centre=(x, y, h / 2 - 0.3), rot=(lean[0], lean[1], rng.uniform(0, pi)),
              jitter=0.14, taper=0.35, cuts=[((rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), 1), 0.6)])
    for i in range(9):
        a = 2 * pi * i / 9 + rng.uniform(-0.1, 0.1)
        if i == 5:  # fallen, lying outwards
            stone(bm, rng, (1.3, 0.5, 0.42), 20, centre=(6.6 * cos(a), 6.6 * sin(a), 0.2), rot=(0, 0, a), jitter=0.12)
            continue
        menhir(5.5 * cos(a), 5.5 * sin(a), rng.uniform(1.8, 3.0), rng.uniform(0.45, 0.6), (rng.uniform(-0.08, 0.08), rng.uniform(-0.08, 0.08)))
    stone(bm, rng, (1.1, 0.8, 0.3), 20, centre=(0, 0, 0.2), jitter=0.08, cuts=[((0, 0, 1), 0.5)])
    menhir(-1.5, 8.5, 4.2, 0.75, (0.12, -0.05))
    for f in bm.faces:
        f.material_index = 1 if f.normal.z > 0.75 else 0


# --- Village-square features ----------------------------------------------------------------------

def well(bm):
    """Round stone well 1.9 m across, dark water inside, two posts with a windlass and a crank, a small
    tiled roof, a bucket on the rim."""
    STONE, ROOF, WOOD, WATER = range(4)
    n = 12
    for i in range(n):
        a0, a1 = 2 * pi * i / n, 2 * pi * (i + 1) / n
        arc_block(bm, 0.62, 0.95, a0, a1, -0.6, 0.78, STONE)
        arc_block(bm, 0.58, 1.02, a0 - 0.01, a1 + 0.01, 0.78, 0.9, STONE)
    frustum(bm, (0, 0), 0.64, 0.64, -0.6, 0.25, WATER)
    for x in (-0.82, 0.82):
        box(bm, (x - 0.08, -0.08, 0.7), (x + 0.08, 0.08, 2.25), WOOD)
    prism(bm, [Vector((-0.95, 0.09 * cos(2 * pi * i / 6), 1.75 + 0.09 * sin(2 * pi * i / 6))) for i in range(6)], Vector((1.9, 0, 0)), WOOD)
    box(bm, (0.95, -0.03, 1.72), (1.02, 0.03, 2.0), WOOD)  # crank
    box(bm, (0.95, -0.2, 1.97), (1.02, 0.03, 2.03), WOOD)
    stick(bm, (0, 0, 1.7), (0, 0, 1.1), 0.02, 0.02, WOOD)  # rope
    frustum(bm, (0, 0), 0.16, 0.2, 0.82, 1.1, WOOD, n=8)  # bucket on the rope
    frustum(bm, (0.78, 0.45), 0.15, 0.19, 0.9, 1.18, WOOD, n=8)  # spare bucket on the rim
    box(bm, (-0.95, -0.12, 2.2), (0.95, 0.12, 2.3), WOOD)  # ridge beam
    roof(bm, -0.85, 0.85, 1.0, 2.15, 42, 0.32, 0.18, 3, thick=0.08)


def fountain(bm):
    """Octagonal fountain 3.4 m across: basin walls with a coping, water in it, a column with a bowl,
    four spouts with their jets and a finial."""
    STONE, WATER, TRIM = range(3)
    n = 8
    for i in range(n):
        a0, a1 = 2 * pi * (i - 0.5) / n, 2 * pi * (i + 0.5) / n
        arc_block(bm, 1.45, 1.7, a0, a1, -0.5, 0.52, STONE)
        arc_block(bm, 1.4, 1.78, a0, a1, 0.52, 0.64, TRIM)
    frustum(bm, (0, 0), 1.46, 1.46, -0.5, 0.42, WATER, n=8, phase=-pi / 8)
    frustum(bm, (0, 0), 0.42, 0.34, 0.4, 0.62, TRIM, n=8)
    frustum(bm, (0, 0), 0.22, 0.2, 0.62, 1.25, STONE, n=8)
    frustum(bm, (0, 0), 0.22, 0.62, 1.25, 1.45, TRIM, n=8)
    frustum(bm, (0, 0), 0.6, 0.6, 1.4, 1.43, WATER, n=8)
    frustum(bm, (0, 0), 0.16, 0.05, 1.45, 1.95, STONE, n=8)
    cone(bm, (0, 0, 1.93), 0.1, 0.2, TRIM, n=6)
    for k in range(4):
        a = pi / 4 + k * pi / 2
        d = Vector((cos(a), sin(a), 0))
        para(bm, d * 0.3 + Z * 0.98, d * 0.25, Vector((-d.y, d.x, 0)) * 0.08, Z * 0.08, TRIM)
        stick(bm, d * 0.43 + Z * 0.97, d * 0.9 + Z * 0.43, 0.06, 0.06, WATER)


def stall(bm):
    """Market stall 2.4 x 1.3 m: counter on four posts with a cloth skirt, crates of produce on it,
    a striped awning sloping to the front with a scalloped valance, crates stacked beside."""
    WOOD, AWN_A, AWN_B, PRODUCE, CRATE = range(5)
    x0, x1, y0, y1 = -1.2, 1.2, -0.65, 0.65
    for x in (x0 + 0.06, x1 - 0.06):
        box(bm, (x - 0.05, y0, -0.2), (x + 0.05, y0 + 0.1, 2.15), WOOD)
        box(bm, (x - 0.05, y1 - 0.1, -0.2), (x + 0.05, y1, 2.5), WOOD)
    box(bm, (x0, y0, 0.84), (x1, y1, 0.9), WOOD)
    box(bm, (x0 + 0.04, y0 - 0.02, 0.15), (x1 - 0.04, y0 + 0.02, 0.84), AWN_B)  # skirt
    box(bm, (x0 + 0.1, y1 - 0.1, 0.5), (x1 - 0.1, y1 - 0.04, 0.84), WOOD)
    stripes = 8
    for i in range(stripes):  # awning boards from the back (2.55 m) to past the front (2.05 m)
        xa, xb = x0 - 0.15 + (x1 - x0 + 0.3) * i / stripes, x0 - 0.15 + (x1 - x0 + 0.3) * (i + 1) / stripes
        mat = AWN_A if i % 2 == 0 else AWN_B
        prism(bm, [Vector((xa, y1 + 0.1, 2.55)), Vector((xa, y0 - 0.45, 2.05)), Vector((xa, y0 - 0.45, 2.0)), Vector((xa, y1 + 0.1, 2.5))],
              Vector((xb - xa, 0, 0)), mat)
        xm = (xa + xb) / 2
        prism(bm, [Vector((xa, y0 - 0.44, 2.03)), Vector((xb, y0 - 0.44, 2.03)), Vector((xm, y0 - 0.44, 1.78))], Vector((0, 0.03, 0)), mat)
    for k, x in enumerate((-0.75, 0.0, 0.75)):  # crates of produce on the counter
        box(bm, (x - 0.3, -0.35, 0.9), (x + 0.3, 0.15, 1.08), CRATE)
        for j in range(6):
            lump(bm, (x - 0.18 + 0.18 * (j % 3), -0.22 + 0.24 * (j // 3), 1.1), 0.09 + 0.01 * ((j + k) % 2), PRODUCE)
    for c, s, rz in (((1.6, 0.3, 0.17), 0.34, 0.2), ((1.62, 0.32, 0.51), 0.3, -0.1), ((1.55, -0.35, 0.15), 0.3, 0.5)):
        block(bm, c, (s * 1.4, s, s), (0, 0, rz), CRATE)
    for j in range(4):
        lump(bm, (1.5 + 0.13 * (j % 2), -0.42 + 0.14 * (j // 2), 0.33), 0.08, PRODUCE)


# --- Build ----------------------------------------------------------------------------------------

def build(name, fn, slots, palette, reach):
    bm = bmesh.new()
    fn(bm)
    assert {f.material_index for f in bm.faces} == set(range(len(slots))), name + ": empty material slot"
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Same as make_houses.build: triangulate and sort so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    for f in bm.faces:
        f.smooth = False
    bake_shade(bm, reach, strength=0.5, base=0.85)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    xs, ys, zs = ([v.co[i] for v in bm.verts] for i in range(3))
    print(f"{name}: {len(bm.faces)} triangles, x {min(xs):.1f}..{max(xs):.1f}, y {min(ys):.1f}..{max(ys):.1f}, "
          f"z {min(zs):.1f}..{max(zs):.1f} m")
    bm.free()
    for i, slot in enumerate(slots):
        mesh.materials.append(material(f"{name}_{slot}", palette[i], 0.4 if slot in ("glass", "water") else 0.9))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))


if __name__ == "__main__":
    bpy.ops.wm.read_factory_settings(use_empty=True)
    os.makedirs(OUT, exist_ok=True)
    build("tower", tower, ("stone", "dark", "ivy", "hole"), ["limestone", "stone", "leaf_deep", "ink"], 3.0)
    build("windmill", windmill, ("wall", "roof", "wood", "glass", "stone"), ["cream", "bark", "bark", "ink", "limestone"], 2.5)
    build("windmill_sails", windmill_sails, ("wood", "cloth"), ["bark", "cream"], 0.15)  # short reach: the lattice would grey the cloth
    build("bridge", bridge, ("stone", "trim", "ivy"), ["limestone", "stone", "leaf_deep"], 3.0)
    build("chapel", chapel, ("wall", "roof", "wood", "glass", "stone", "bell"),
          ["limestone", "terracotta", "bark", "ink", "stone", "gold"], 2.5)
    build("stones", stones, ("stone", "moss"), ["stone", "leaf"], 1.5)
    build("well", well, ("stone", "roof", "wood", "water"), ["limestone", "slate", "bark", "ink"], 1.0)
    build("fountain", fountain, ("stone", "water", "trim"), ["limestone", "water", "stone"], 1.0)
    build("stall_0", stall, ("wood", "awning", "stripe", "produce", "crate"), ["bark", "terracotta", "cream", "gold", "ochre"], 1.2)
    build("stall_1", stall, ("wood", "awning", "stripe", "produce", "crate"), ["bark", "leaf", "cream", "terracotta", "ochre"], 1.2)
    build("stall_2", stall, ("wood", "awning", "stripe", "produce", "crate"), ["bark", "water", "cream", "leaf_light", "ochre"], 1.2)
