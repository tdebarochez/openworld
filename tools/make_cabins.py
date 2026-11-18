"""Generate three lakeside cabins and their pontoons as .glb files for Godot:
cabin_0 fisherman's plank hut (falu-red board-and-batten, cream trim, barrels and oars), cabin_1 small
log cabin (crossed log corners, gable to the lake over a railed porch, stone chimney, firewood) and
cabin_2 stilt cabin (raised plank hut on braced posts, wrap balcony, outside stair, a canoe beneath),
with pier_0..2: pier_0 straight with a rowboat, pier_1 an L ending in a bench with a boat along the
arm, pier_2 a T with a handrail and a moored boat.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_cabins.py
Then: godot --headless --path . --import

Cabins follow tools/make_houses.py (whose helpers they reuse): origin at the footprint centre on the
ground, the lake side (door, porch, balcony) on -Y in Blender (+Z in Godot), stone or posts going down
to -1.2 m for uneven ground, flat-shaded, baked shading (make_trees.bake_shade). Material slots: walls,
roof, wood (frames, doors, rails), glass, stone, raw wood (props); seasons.gd snows on slot 1 (roof).
Piers: origin on the shoreline at the water level, reaching out along -Y (+Z in Godot): a plank deck
DECK m above the water on posts going down to -4 m, and a ramp down onto the shore behind the origin
(+Y). Slots: deck, posts, boat paint, rope. world.gd collides with both as trimeshes, so the deck,
porches and stairs are walkable. No randomness, so re-running gives the same files.
"""
import os
import sys
from math import cos, pi, radians, sin, tan

import bmesh
import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_houses import (GLASS, ROOF, STONE, WALL, WOOD, Z, balcony, barge, box, chalet_window,  # noqa: E402
                         chimney, firewood, gable, log_facade, material, para, plank_door, prism, ring, roof,
                         sides, turn)
from make_trees import bake_shade, export  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "cabins")
RAW = 5  # sixth cabin slot: unpainted wood (benches, barrels, steps)
DECK_M, POST, PAINT, ROPE = range(4)  # pier slots
DECK = 0.45  # pier deck top above the water


# --- Shared bits ----------------------------------------------------------------------------------

def stick(bm, a, b, width, thick, mat):
    """Square-ish member from a to b (oars, braces, rails)."""
    a, b = Vector(a), Vector(b)
    u = b - a
    side = (u.cross(Z) if abs(u.normalized().z) < 0.95 else Vector((1, 0, 0))).normalized()
    para(bm, (a + b) / 2, u, side * width, u.cross(side).normalized() * thick, mat)


def post(bm, x, y, z0, z1, mat, r=0.09):
    """Round (hexagonal) post from z0 to z1."""
    prism(bm, ring((x, y, z0), r, 6), Vector((0, 0, z1 - z0)), mat)


def barrel(bm, x, y, mat, hoop, h=0.75, r=0.27):
    prism(bm, ring((x, y, 0), r * 0.9, 8), Vector((0, 0, h)), mat)
    prism(bm, ring((x, y, h * 0.2), r, 8), Vector((0, 0, h * 0.6)), mat)  # the bulge
    for z in (h * 0.12, h * 0.8):
        prism(bm, ring((x, y, z), r * 1.02, 8), Vector((0, 0, 0.05)), hoop)


def boat(bm, c, angle, length, beam, hull, inside, rim, depth=0.42):
    """Rowboat (or canoe when narrow) floating with its waterline at c.z, length along `angle`:
    pointed bow, small transom, hull lofted from keel to gunwale (sheer rising to the bow), an open
    inside with a floor, two thwarts and a pair of oars."""
    prof = [(-0.5, 0.62), (-0.33, 0.88), (-0.05, 1.0), (0.22, 0.9), (0.38, 0.55), (0.5, 0.0)]
    top = [(x, w) for x, w in prof] + [(x, -w) for x, w in reversed(prof[:-1])]
    cs, sn = cos(angle), sin(angle)

    def at(x, y, z):
        return Vector((c[0] + x * cs - y * sn, c[1] + x * sn + y * cs, c[2] + z))
    z_keel, z_gun = -0.15, depth - 0.15

    def loop(sx, sy, z, lift=0.0):
        return [bm.verts.new(at(x * length * sx, w * beam / 2 * sy, z + lift * max(0.0, x) * 2)) for x, w in top]
    keel = loop(0.86, 0.45, z_keel, 0.12)
    gun = loop(1.0, 1.0, z_gun, 0.12)
    lip = loop(0.95, 0.86, z_gun, 0.12)
    floor = loop(0.82, 0.5, z_keel + 0.12, 0.12)
    n = len(top)
    bm.faces.new(keel[::-1]).material_index = hull
    bm.faces.new(floor).material_index = inside
    for a, b, m in ((keel, gun, hull), (gun, lip, rim), (lip, floor, inside)):
        for i in range(n):
            bm.faces.new([a[i - 1], a[i], b[i], b[i - 1]]).material_index = m
    for x in (-0.18 * length, 0.12 * length):  # thwarts
        half = beam / 2 * 0.88 * (0.97 if x < 0 else 0.95)
        stick(bm, at(x, -half, z_gun - 0.1), at(x, half, z_gun - 0.1), 0.2, 0.04, rim)
    for s in (-1, 1):  # oars resting in the boat
        stick(bm, at(-0.4 * length, s * beam * 0.18, z_keel + 0.2), at(0.3 * length, s * beam * 0.12, z_keel + 0.28),
              0.05, 0.05, rim)
        stick(bm, at(-0.42 * length, s * beam * 0.18, z_keel + 0.2), at(-0.28 * length, s * beam * 0.18, z_keel + 0.2),
              0.14, 0.02, rim)


# --- Piers (origin on the shoreline at the water level, out along -Y) -----------------------------

def walkway(bm, x0, x1, y0, y1, spacing=2.0, phase=0):
    """Deck from y0 out to y1 (< y0), x0..x1 wide: planks across with gaps, a little uneven, on two
    stringers and cross beams, pairs of posts down into the lake bed."""
    n = round((y0 - y1) / 0.2)
    step = (y0 - y1) / n
    for i in range(n):
        ya = y0 - i * step
        jx = 0.035 * ((i * 7 + phase) % 3 - 1)
        dz = 0.01 * ((i * 5 + phase) % 3 - 1)
        box(bm, (x0 - 0.04 + jx, ya - step + 0.025, DECK - 0.05 + dz), (x1 + 0.04 + jx, ya, DECK + dz), DECK_M)
    for x in (x0 + 0.15, x1 - 0.15):
        box(bm, (x - 0.06, y1 + 0.05, DECK - 0.24), (x + 0.06, y0 - 0.05, DECK - 0.05), POST)
    k = max(1, round((y0 - y1) / spacing))
    for i in range(k + 1):
        y = y0 - 0.12 - i * (y0 - y1 - 0.24) / k
        box(bm, (x0, y - 0.06, DECK - 0.36), (x1, y + 0.06, DECK - 0.24), POST)
        for x in (x0 + 0.02, x1 - 0.02):
            post(bm, x, y, -4.0, DECK - 0.05, POST)


def ramp(bm, x0, x1, y0, length=1.6):
    """Boards from the deck's shore end (y0) sloping down into the ground behind it, with cleats."""
    a, b = Vector(((x0 + x1) / 2, y0, DECK - 0.03)), Vector(((x0 + x1) / 2, y0 + length, -0.15))
    u = b - a
    para(bm, (a + b) / 2, u, Vector((x1 - x0, 0, 0)), u.cross(Vector((1, 0, 0))).normalized() * -0.06, DECK_M)
    for t in (0.25, 0.5, 0.75):
        p = a.lerp(b, t) + Vector((0, 0, 0.04))
        box(bm, (x0 + 0.08, p.y - 0.03, p.z - 0.02), (x1 - 0.08, p.y + 0.03, p.z + 0.02), POST)


def bollard(bm, x, y, rope=True):
    post(bm, x, y, -4.0, DECK + 0.45, POST, r=0.12)
    prism(bm, ring((x, y, DECK + 0.45), 0.14, 6), Vector((0, 0, 0.05)), POST)
    if rope:
        prism(bm, ring((x, y, DECK + 0.22), 0.15, 6), Vector((0, 0, 0.1)), ROPE)


def ladder(bm, x, y, out):
    """Swimming ladder hanging off the deck edge at y, `out` = ±1 the way it faces (along Y)."""
    for s in (-0.22, 0.22):
        stick(bm, (x + s, y + out * 0.08, DECK + 0.55), (x + s, y + out * 0.2, -1.1), 0.06, 0.06, POST)
    for k in range(5):
        z = DECK - 0.25 - k * 0.32
        e = 0.08 + 0.12 * (DECK + 0.55 - z) / (DECK + 1.65)
        box(bm, (x - 0.22, y + out * e - 0.03, z - 0.025), (x + 0.22, y + out * e + 0.03, z + 0.025), POST)


def coil(bm, x, y):
    prism(bm, ring((x, y, DECK), 0.22, 8), Vector((0, 0, 0.07)), ROPE)
    prism(bm, ring((x + 0.02, y, DECK + 0.07), 0.16, 8), Vector((0, 0, 0.05)), ROPE)


def pier_0(bm):
    """Straight pier, 9 m out, a rowboat tied alongside, a ladder at the end."""
    walkway(bm, -0.7, 0.7, 1.0, -9.0)
    ramp(bm, -0.7, 0.7, 1.0)
    for x in (-0.75, 0.75):
        bollard(bm, x, -8.9, rope=x < 0)
    ladder(bm, 0.25, -9.0, -1)
    coil(bm, 0.35, -7.6)
    box(bm, (-0.45, -6.4, DECK), (0.05, -5.85, DECK + 0.32), POST)  # fish crate
    box(bm, (-0.4, -6.35, DECK + 0.32), (0.0, -5.9, DECK + 0.34), DECK_M)
    boat(bm, (-1.55, -7.4, 0.0), pi / 2 + 0.06, 3.4, 1.35, PAINT, POST, DECK_M)
    stick(bm, (-0.75, -8.9, DECK + 0.27), (-1.5, -9.0, 0.32), 0.035, 0.035, ROPE)


def pier_1(bm):
    """L-shaped pier: 7 m out, then an arm to the right ending in a bench facing the lake; a boat
    moored along the arm."""
    walkway(bm, -0.6, 0.6, 1.0, -7.0)
    ramp(bm, -0.6, 0.6, 1.0)
    walkway(bm, -0.6, 3.8, -7.0, -8.6, phase=1)
    for x, y in ((3.85, -8.55), (3.85, -7.05), (-0.65, -8.55)):
        bollard(bm, x, y, rope=y < -8)
    for x in (2.2, 3.4):  # bench legs, seat, backrest
        box(bm, (x - 0.05, -7.45, DECK), (x + 0.05, -7.05, DECK + 0.42), POST)
        box(bm, (x - 0.04, -7.12, DECK + 0.42), (x + 0.04, -7.06, DECK + 0.85), POST)
    box(bm, (1.95, -7.5, DECK + 0.42), (3.65, -7.05, DECK + 0.47), DECK_M)
    box(bm, (1.95, -7.13, DECK + 0.62), (3.65, -7.08, DECK + 0.78), DECK_M)
    coil(bm, -0.25, -8.1)
    boat(bm, (2.0, -9.35, 0.0), 0.04, 3.2, 1.3, PAINT, POST, DECK_M)
    stick(bm, (3.85, -8.55, DECK + 0.27), (3.55, -9.3, 0.4), 0.035, 0.035, ROPE)


def pier_2(bm):
    """T-shaped pier 11 m out with a handrail along the walkway, a boat moored at the head."""
    walkway(bm, -0.6, 0.6, 1.0, -9.0)
    ramp(bm, -0.6, 0.6, 1.0)
    walkway(bm, -2.8, 2.8, -9.0, -11.0, phase=2)
    for k in range(6):  # handrail on the right
        y = 0.6 - k * 1.9
        post(bm, 0.66, y, DECK - 0.3, DECK + 0.95, POST, r=0.06)
    stick(bm, (0.66, 0.6, DECK + 0.95), (0.66, -8.9, DECK + 0.95), 0.08, 0.06, DECK_M)
    stick(bm, (0.66, 0.6, DECK + 0.5), (0.66, -8.9, DECK + 0.5), 0.04, 0.04, ROPE)
    for x, y in ((-2.85, -10.95), (2.85, -10.95), (-2.85, -9.05), (2.85, -9.05)):
        bollard(bm, x, y, rope=x > 0 and y < -10)
    ladder(bm, -1.4, -11.0, -1)
    coil(bm, 2.2, -9.5)
    boat(bm, (1.2, -11.85, 0.0), 0.0, 3.6, 1.35, PAINT, POST, DECK_M)
    stick(bm, (2.85, -10.95, DECK + 0.27), (2.9, -11.75, 0.4), 0.035, 0.035, ROPE)


# --- Cabins (origin at the footprint centre on the ground, lake side -Y) --------------------------

def board_wall(bm, w, z0, z1, gable_rise=0.0, step=0.42, mat=WALL):
    """Battens every `step` over a board wall, same paint, up to the gable line when gable_rise > 0."""
    m = w.length / 2
    s = step / 2
    while s < w.length - 0.1:
        top = z1 + gable_rise * (1 - abs(s - m) / m) - (0.12 if gable_rise else 0.05)
        w.box(bm, s - 0.04, s + 0.04, z0, top, 0, 0.035, mat)
        s += step


def fisher_hut(bm):
    """cabin_0: fisherman's hut. Falu-red board-and-batten walls with cream corner boards, barge
    boards and frames, on stone piers; slate roof with a stove pipe, flower box under the window,
    a bench by the door, barrels and oars along the sides."""
    w, d, base, h = 3.8, 3.0, 0.45, 2.45
    pitch, over_side, over_gable = 32, 0.45, 0.35
    for x in (-w / 2 + 0.2, 0.0, w / 2 - 0.2):
        for y in (-d / 2 + 0.2, d / 2 - 0.2):
            box(bm, (x - 0.2, y - 0.2, -1.2), (x + 0.2, y + 0.2, base - 0.16), STONE)
    box(bm, (-w / 2 - 0.05, -d / 2 - 0.05, base - 0.18), (w / 2 + 0.05, d / 2 + 0.05, base), RAW)  # sill beams
    box(bm, (-w / 2, -d / 2, base), (w / 2, d / 2, h), WALL)
    rise = roof(bm, -w / 2, w / 2, d, h, pitch, over_side, over_gable, 6)
    ws = sides(-w / 2, w / 2, -d / 2, d / 2)
    for wall in ws:
        gabled = wall in (ws[1], ws[3])
        if gabled:
            gable(bm, wall, h, rise, WALL)
        board_wall(bm, wall, base, h, rise if gabled else 0.0)
        for s0, s1 in ((-0.06, 0.12), (wall.length - 0.12, wall.length + 0.06)):  # corner boards
            wall.box(bm, s0, s1, base - 0.1, h, 0, 0.06, WOOD)
    for x in (w / 2 + over_gable, -w / 2 - over_gable):
        barge(bm, x, d, h, rise, over_side, pitch, teeth=False)
    plank_door(bm, ws[0], 1.0, 0.85, 1.8, base)
    chalet_window(bm, ws[0], 2.75, 1.3, 0.75, 0.7, shutters=False)
    chalet_window(bm, ws[1], 1.5, 1.35, 0.5, 0.5, shutters=False, sill=False)
    chalet_window(bm, ws[3], 1.5, 1.35, 0.5, 0.5, shutters=False, sill=False)
    ws[0].box(bm, 0.45, 1.55, -0.3, 0.22, 0, 0.4, RAW)  # step
    for s in (2.25, 3.25):  # bench along the front
        ws[0].box(bm, s - 0.05, s + 0.05, 0, 0.42, 0.15, 0.45, RAW)
    ws[0].box(bm, 2.1, 3.4, 0.42, 0.47, 0.1, 0.48, RAW)
    barrel(bm, w / 2 + 0.42, -d / 2 + 0.45, RAW, GLASS)
    barrel(bm, w / 2 + 0.45, -d / 2 + 1.05, RAW, GLASS, h=0.6, r=0.24)
    box(bm, (w / 2 + 0.2, d / 2 - 1.0, 0), (w / 2 + 0.7, d / 2 - 0.4, 0.45), RAW)  # crate
    for k, y in enumerate((-0.6, -0.15)):  # oars leaning on the left wall, blades up
        a, b = Vector((-w / 2 - 0.55, y, 0)), Vector((-w / 2 - 0.1, y + 0.25 * k, 2.2))
        stick(bm, a, b, 0.05, 0.05, RAW)
        stick(bm, a.lerp(b, 0.72), b + (b - a).normalized() * 0.12, 0.15, 0.025, RAW)
    # Stove pipe through the back slope, with a cap.
    zp = h + (d / 2 - 0.7) * tan(radians(pitch))
    post(bm, -0.9, 0.7, zp - 0.4, zp + 1.0, GLASS, r=0.08)
    prism(bm, ring((-0.9, 0.7, zp + 1.0), 0.16, 6), Vector((0, 0, 0.06)), GLASS)


def log_cabin(bm):
    """cabin_1: small log cabin with its gable to the lake. Crossed log corners on a stone base, a
    railed porch under the roof, door and shuttered windows, stone chimney at the back, firewood
    under the side eave, a bench on the porch. Built door to +X, then turned."""
    L, S, base, h = 5.0, 4.0, 0.5, 2.7
    pitch, over_side, over_gable, porch = 33, 0.55, 0.4, 1.6
    box(bm, (-L / 2 - 0.12, -S / 2 - 0.12, -1.2), (L / 2 + 0.12, S / 2 + 0.12, base), STONE)
    box(bm, (-L / 2, -S / 2, base), (L / 2, S / 2, h), WALL)
    rise = roof(bm, -L / 2, L / 2 + porch, S, h, pitch, over_side, over_gable, 7)
    for x in (L / 2 + porch + over_gable, -L / 2 - over_gable):
        barge(bm, x, S, h, rise, over_side, pitch, teeth=x > 0)
    ws = sides(-L / 2, L / 2, -S / 2, S / 2)
    for wall in (ws[1], ws[3]):
        gable(bm, wall, h, rise, WALL)
        board_wall(bm, wall, h, h, rise, step=0.5, mat=WOOD)
    log_facade(bm, ws[1], base, h, [(2.95, 1.3, 0.8, 0.85)], door=(1.2, base, 0.9, 1.95))
    log_facade(bm, ws[0], base, h, [(2.6, 1.3, 0.8, 0.85)], phase=0.17)
    log_facade(bm, ws[2], base, h, [(1.9, 1.3, 0.8, 0.85)], phase=0.17)
    log_facade(bm, ws[3], base, h, [(1.2, 1.4, 0.6, 0.6)])
    chalet_window(bm, ws[1], S / 2, h + 0.2, 0.55, 0.55, shutters=False, sill=False)  # in the gable
    # Porch: railed deck with a gap in front of the door, posts up to the roof, steps down.
    balcony(bm, ws[1], -0.45, S + 0.45, base, porch, gap=(0.7, 1.7), rail=0.85, brackets=[])
    for s in (-0.38, 0.62, 1.78, S + 0.38):
        ws[1].box(bm, s - 0.07, s + 0.07, -0.8, base - 0.12, porch - 0.16, porch - 0.02, WOOD)
    for s in (-0.38, S + 0.38):
        ws[1].box(bm, s - 0.07, s + 0.07, base, h - 0.22, porch - 0.16, porch - 0.02, WOOD)
    for k in range(2):
        ws[1].box(bm, 0.7, 1.7, -0.4, base - (k + 1) * base / 3, porch + 0.3 * k, porch + 0.3 * (k + 1), RAW)
    for s in (2.5, 3.5):  # porch bench under the window
        ws[1].box(bm, s - 0.05, s + 0.05, base, base + 0.42, 0.12, 0.42, RAW)
    ws[1].box(bm, 2.3, 3.7, base + 0.42, base + 0.47, 0.08, 0.46, RAW)
    firewood(bm, ws[0], 0.5, 3.3, 0, 3)
    chimney(bm, -L / 2 + 0.7, 0.9, h - 0.5, h + rise + 0.3)
    turn(bm, -pi / 2)


def stilt_cabin(bm):
    """cabin_2: plank cabin raised on braced posts, steep tiled roof with toothed barge boards, a
    balcony along the lake side reached by an outside stair, shuttered windows, a canoe resting on
    trestles underneath."""
    w, d, f, h = 4.4, 3.4, 1.9, 4.3  # f: floor top
    pitch, over_side, over_gable, depth = 40, 0.5, 0.45, 1.3
    for x in (-w / 2 + 0.15, 0.0, w / 2 - 0.15):
        for y in (-d / 2 - depth + 0.1, -d / 2 + 0.15, d / 2 - 0.15):
            post(bm, x, y, 0.0, f - 0.2, WOOD, r=0.11)
            box(bm, (x - 0.2, y - 0.2, -1.2), (x + 0.2, y + 0.2, 0.12), STONE)  # footing
    for y in (-d / 2 + 0.15, d / 2 - 0.15):  # cross bracing between the posts
        for x0, x1 in ((-w / 2 + 0.15, 0.0), (0.0, w / 2 - 0.15)):
            stick(bm, (x0, y, 0.15), (x1, y, f - 0.35), 0.08, 0.1, WOOD)
    for x in (-w / 2 + 0.15, w / 2 - 0.15):
        stick(bm, (x, -d / 2 + 0.15, f - 0.35), (x, d / 2 - 0.15, 0.15), 0.08, 0.1, WOOD)
    box(bm, (-w / 2 - 0.05, -d / 2 - 0.05, f - 0.28), (w / 2 + 0.05, d / 2 + 0.05, f), WOOD)  # floor frame
    box(bm, (-w / 2, -d / 2, f), (w / 2, d / 2, h), WALL)
    rise = roof(bm, -w / 2, w / 2, d, h, pitch, over_side, over_gable, 8)
    ws = sides(-w / 2, w / 2, -d / 2, d / 2)
    for wall in ws:
        gabled = wall in (ws[1], ws[3])
        if gabled:
            gable(bm, wall, h, rise, WALL)
        board_wall(bm, wall, f, h, rise if gabled else 0.0, mat=WOOD)
    for x in (w / 2 + over_gable, -w / 2 - over_gable):
        barge(bm, x, d, h, rise, over_side, pitch)
    plank_door(bm, ws[0], 1.3, 0.85, 1.9, f)
    chalet_window(bm, ws[0], 3.1, f + 0.8, 0.8, 0.85)
    chalet_window(bm, ws[2], 2.2, f + 0.8, 0.8, 0.85)
    chalet_window(bm, ws[1], d / 2, f + 0.8, 0.65, 0.75)
    chalet_window(bm, ws[1], d / 2, h + 0.35, 0.45, 0.5, shutters=False, sill=False)
    balcony(bm, ws[0], -0.1, w + 0.1, f, depth, gap=(w - 1.0, w + 0.1), rail=0.9, brackets=[])
    # Stair from the balcony's right end down to the ground, along the lake side.
    y0, y1, n = -d / 2 - depth + 0.05, -d / 2 - 0.35, 8
    for k in range(n):
        z = f - (k + 1) * f / (n + 1)
        x = w / 2 + 0.1 + k * 0.3
        box(bm, (x, y0, z - 0.05), (x + 0.32, y1, z), WOOD)
    for y in (y0 - 0.04, y1 + 0.04):
        stick(bm, (w / 2 + 0.05, y, f - 0.05), (w / 2 + 0.1 + n * 0.3 + 0.5, y, -1.0), 0.05, 0.22, WOOD)
    stick(bm, (w / 2 + 0.05, y0 - 0.04, f + 0.9), (w / 2 + 0.1 + n * 0.3 + 0.05, y0 - 0.04, 0.85), 0.07, 0.06, WOOD)
    post(bm, w / 2 + 0.1 + n * 0.3 + 0.05, y0 - 0.04, -0.3, 0.9, WOOD, r=0.05)
    # Canoe on two trestles under the floor.
    for x in (-1.1, 0.9):
        stick(bm, (x, -0.55, 0.0), (x, -0.25, 0.42), 0.06, 0.06, WOOD)
        stick(bm, (x, 0.55, 0.0), (x, 0.25, 0.42), 0.06, 0.06, WOOD)
        box(bm, (x - 0.05, -0.45, 0.4), (x + 0.05, 0.45, 0.46), WOOD)
    boat(bm, (-0.1, 0.0, 0.62), 0.0, 3.6, 0.8, RAW, WOOD, WOOD, depth=0.36)
    post(bm, -w / 2 + 0.55, d / 2 - 0.6, h + (0.6 - 0.15) * tan(radians(pitch)) - 0.4, h + rise + 0.25, GLASS, r=0.08)


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
          f"z ..{max(zs):.1f} m")
    bm.free()
    for i, slot in enumerate(slots):
        mesh.materials.append(material(f"{name}_{slot}", palette[i], 0.4 if slot == "glass" else 0.9))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))


if __name__ == "__main__":
    bpy.ops.wm.read_factory_settings(use_empty=True)
    os.makedirs(OUT, exist_ok=True)
    cabin = ("wall", "roof", "wood", "glass", "stone", "raw")
    pier = ("deck", "post", "paint", "rope")
    build("cabin_0", fisher_hut, cabin, ["terracotta", "slate", "cream", "ink", "stone", "bark"], 2.0)
    build("cabin_1", log_cabin, cabin, ["ochre", "leaf_deep", "bark", "ink", "stone", "sand"], 2.0)
    build("cabin_2", stilt_cabin, cabin, ["sand", "terracotta", "bark", "ink", "stone", "water"], 2.0)
    build("pier_0", pier_0, pier, ["ochre", "bark", "water", "cream"], 1.2)
    build("pier_1", pier_1, pier, ["ochre", "bark", "terracotta", "cream"], 1.2)
    build("pier_2", pier_2, pier, ["ochre", "bark", "cream", "cream"], 1.2)
