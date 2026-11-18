"""Generate six village houses as .glb files for Godot, three per style: medieval (house_0..2: stone
ground floor, half-timbered or rendered upper floor, steep tiled roof) and Alpine chalet (house_3..5:
log walls with crossed corners, stone base, low wide roof on purlins, wooden balconies).

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_houses.py
Then: godot --headless --path . --import

Flat-shaded boxes, prisms and slabs, 2200-3000 triangles a house. Materials in slot order: walls
(plaster or logs), roof, wood (timbers, doors, shutters, balconies), windows, stone. Every house uses
all five (the exporter drops empty slots), and seasons.gd snows on slot 1 (roof) only, so balconies,
sills and beams stay bare. Origin at the footprint centre on the ground; the stone plinth goes 1.5 m
below y=0 so the house sits on uneven ground without gaps. The door is on the -Y side in Blender (+Z in
Godot), within 1.2 m of x=0: world.gd puts a street lamp 2.4 m to its right, in front of everything
lower than the lantern. world.gd's collision box is the wall and stone vertices between 0.25 and 1.2 m
high (plinth top, foot of the walls), so what sticks out at that height (steps, firewood) is wood.
Soft occlusion (under eaves, balconies, in corners, at the foot of the walls) is baked as vertex
colour by tools/make_trees.py bake_shade. No randomness, so re-running gives the same files.
"""
import json
import os
import sys
from math import cos, pi, radians, sin, tan

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True  # no __pycache__ in tools/
from make_trees import bake_shade, export  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "houses")
WALL, ROOF, WOOD, GLASS, STONE = range(5)
Z = Vector((0, 0, 1))
PLINTH = 0.3  # default top of the stone plinth
LOG = 0.34  # height of a wall log
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "palette.json")) as f:
    PALETTE = json.load(f)["colours"]


def linear(colour):
    """Blender/glTF colours are linear; the game's palette (assets/palette.json) is sRGB hex, by name."""
    srgb = (int(PALETTE[colour][i:i + 2], 16) / 255 for i in (1, 3, 5))
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def material(name, colour, roughness):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*linear(colour), 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    return m


# --- Solids ---------------------------------------------------------------------------------------

def para(bm, c, u, v, w, mat):
    """Parallelepiped centred on `c` with edge vectors u, v, w (a box when they are orthogonal)."""
    m = Matrix((u, v, w)).transposed().to_4x4()
    m.translation = c
    res = bmesh.ops.create_cube(bm, size=1.0, matrix=m)
    for f in {f for v in res["verts"] for f in v.link_faces}:
        f.material_index = mat


def box(bm, lo, hi, mat):
    """Axis-aligned box from corner `lo` to corner `hi`."""
    lo, hi = Vector(lo), Vector(hi)
    d = hi - lo
    para(bm, (lo + hi) / 2, (d.x, 0, 0), (0, d.y, 0), (0, 0, d.z), mat)


def prism(bm, pts, off, mat):
    """Solid between the convex polygon `pts` and the same polygon moved by `off`."""
    a = [bm.verts.new(p) for p in pts]
    b = [bm.verts.new(Vector(p) + off) for p in pts]
    for f in [a[::-1], b] + [[a[i - 1], a[i], b[i], b[i - 1]] for i in range(len(a))]:
        bm.faces.new(f).material_index = mat


def ring(c, r, n=12):
    return [Vector(c) + Vector((r * cos(2 * pi * i / n), r * sin(2 * pi * i / n), 0)) for i in range(n)]


def cone(bm, c, r, h, mat, n=12):
    """Upright n-sided cone on point `c`."""
    base = [bm.verts.new(p) for p in ring(c, r, n)]
    top = bm.verts.new(Vector(c) + Z * h)
    bm.faces.new(base[::-1]).material_index = mat
    for i in range(n):
        bm.faces.new([base[i - 1], base[i], top]).material_index = mat


def turn(bm, angle, verts=None):
    """Turn `verts` (default: all) by `angle` about the vertical axis through the origin."""
    bmesh.ops.rotate(bm, verts=list(bm.verts) if verts is None else verts, cent=(0, 0, 0),
                     matrix=Matrix.Rotation(angle, 3, "Z"))


class Wall:
    """A facade seen from outside: at(s, z, e) is s m from its left end, z m up and e m out of it."""

    def __init__(self, o, along, out, length):
        self.o, self.along, self.out, self.length = Vector(o), Vector(along), Vector(out), length

    def at(self, s, z, e=0.0):
        return self.o + self.along * s + Z * z + self.out * e

    def box(self, bm, s0, s1, z0, z1, e0, e1, mat):
        para(bm, self.at((s0 + s1) / 2, (z0 + z1) / 2, (e0 + e1) / 2),
             self.along * (s1 - s0), Z * (z1 - z0), self.out * (e1 - e0), mat)

    def beam(self, bm, s0, z0, s1, z1, width, e0, e1, mat):
        """Straight member from (s0, z0) to (s1, z1) in the facade plane, `width` across (braces)."""
        a, b = self.at(s0, z0, (e0 + e1) / 2), self.at(s1, z1, (e0 + e1) / 2)
        para(bm, (a + b) / 2, b - a, self.out.cross(b - a).normalized() * width, self.out * (e1 - e0), mat)

    def board(self, bm, s0, s1, p, q, thick, mat):
        """Plank spanning s0..s1 along the facade, from p to q = (z, e) across it (brackets, flaps)."""
        a, b = self.at((s0 + s1) / 2, *p), self.at((s0 + s1) / 2, *q)
        para(bm, (a + b) / 2, self.along * (s1 - s0), b - a, (b - a).cross(self.along).normalized() * thick, mat)

    def prism(self, bm, pts, e0, e1, mat):
        """Convex polygon of (s, z) points, from e0 to e1 out of the facade."""
        prism(bm, [self.at(s, z, e0) for s, z in pts], self.out * (e1 - e0), mat)


def sides(x0, x1, y0, y1):
    """The four walls of an x0..x1 x y0..y1 block: front (-Y, door side), right, back, left."""
    X, Y = Vector((1, 0, 0)), Vector((0, 1, 0))
    return [Wall((x0, y0, 0), X, -Y, x1 - x0), Wall((x1, y0, 0), Y, X, y1 - y0),
            Wall((x1, y1, 0), -X, Y, x1 - x0), Wall((x0, y1, 0), -Y, -X, y1 - y0)]


# --- Building parts -------------------------------------------------------------------------------

def plinth(bm, x0, x1, y0, y1, top=PLINTH):
    box(bm, (x0 - 0.15, y0 - 0.15, -1.5), (x1 + 0.15, y1 + 0.15, top), STONE)


def roof(bm, x0, x1, span, eave, pitch, over_side, over_gable, courses, thick=0.18):
    """Gable roof, ridge along X over walls from x0 to x1 (it reaches `over_gable` further) and `span`
    apart (centred on y=0) that stop at height `eave`: two slabs resting on the walls' outer top edges,
    `courses` rows of tiles or shingles on each (lower edges lifted so they read as steps, and keep the
    roof colour under snow), and a ridge cap. Returns the gable triangles' height."""
    a = radians(pitch)
    rise = span / 2 * tan(a)
    u = Vector((x1 - x0 + 2 * over_gable, 0, 0))
    hi = Vector(((x0 + x1) / 2, 0, eave + rise))
    for s in (-1, 1):
        lo = Vector((hi.x, s * (span / 2 + over_side), eave - over_side * tan(a)))
        n = Vector((0, s * sin(a), cos(a)))
        v = (hi - lo) * (1 + thick * tan(a) / (hi - lo).length)  # past the ridge, so the slabs meet on top
        para(bm, lo + v / 2 + n * thick / 2, u, v, n * thick, ROOF)
        for i in range(courses):
            p = lo + (hi - lo) * (i / courses) + n * (thick + 0.05)
            q = lo + (hi - lo) * min(1.0, (i + 1.35) / courses) + n * thick
            para(bm, (p + q) / 2 + n * 0.025, u, q - p, n * 0.05, ROOF)
    para(bm, hi + Z * thick / cos(a), u, (0, 0.26, 0.2), (0, -0.26, 0.2), ROOF)  # ridge cap
    return rise


def gable(bm, w, eave, rise, mat, depth=0.3):
    """Triangle filling end wall `w` from the eave up under the roof."""
    w.prism(bm, [(0, eave), (w.length, eave), (w.length / 2, eave + rise)], -depth, 0, mat)


def chimney(bm, x, y, z0, z1, cap=ROOF):
    """Stone stack with a cap (roof slot: it gets snow like the roof)."""
    box(bm, (x - 0.33, y - 0.33, z0), (x + 0.33, y + 0.33, z1), STONE)
    box(bm, (x - 0.43, y - 0.43, z1), (x + 0.43, y + 0.43, z1 + 0.12), cap)


def leaded_window(bm, w, s, z, width, height, stone_frame=False, bar=WOOD):
    """Small medieval window centred at s, sill at z: dark glass behind a mullion and a transom; on
    stone or rendered walls, a stone sill, lintel and jambs around it."""
    w.box(bm, s - width / 2, s + width / 2, z, z + height, -0.1, 0.02, GLASS)
    t = 0.03 if bar == WOOD else 0.05
    w.box(bm, s - t, s + t, z, z + height, 0, 0.05, bar)
    zt = z + height * 0.62
    w.box(bm, s - width / 2, s + width / 2, zt - t, zt + t, 0, 0.05, bar)
    if stone_frame:
        f = 0.15
        w.box(bm, s - width / 2 - f, s + width / 2 + f, z - 0.13, z, 0, 0.13, STONE)
        w.box(bm, s - width / 2 - f, s + width / 2 + f, z + height, z + height + 0.2, 0, 0.09, STONE)
        for j in (s - width / 2 - f, s + width / 2):
            w.box(bm, j, j + f, z, z + height, 0, 0.07, STONE)


def chalet_window(bm, w, s, z, width, height, shutters=True, sill=True, shutter_e=0.1):
    """Window (or glazed door) centred at s from height z: wooden lintel, mullion (and a transom on
    doors), flower-box sill and open shutters either side, `shutter_e` out (on the logs' ridges)."""
    w.box(bm, s - width / 2, s + width / 2, z, z + height, -0.1, 0.02, GLASS)
    w.box(bm, s - width / 2 - 0.08, s + width / 2 + 0.08, z + height, z + height + 0.12, 0, 0.14, WOOD)
    if sill:
        w.box(bm, s - width / 2 - 0.08, s + width / 2 + 0.08, z - 0.22, z, 0, 0.22, WOOD)
    w.box(bm, s - 0.03, s + 0.03, z, z + height, 0, 0.05, WOOD)
    if height > 1.5:
        w.box(bm, s - width / 2, s + width / 2, z + height - 0.48, z + height - 0.42, 0, 0.05, WOOD)
    if shutters:
        for side in (-1, 1):
            a, b = s + side * (width / 2 + 0.06), s + side * (width + 0.06)
            w.box(bm, min(a, b), max(a, b), z, z + height, shutter_e, shutter_e + 0.04, WOOD)


def arched_door(bm, w, s, width, height, z=PLINTH):
    """Plank door under a round arch centred at s, framed by stone jambs and voussoirs (an odd number,
    so there is a keystone), alternately proud."""
    r = width / 2
    zs = z + height - r
    n = 7

    def arc(rr, i):
        return s + rr * cos(pi * i / n), zs + rr * sin(pi * i / n)
    w.prism(bm, [(s - r, z), (s + r, z)] + [arc(r, i) for i in range(n + 1)], -0.06, 0.02, WOOD)
    for zz in (z + 0.45, zs - 0.15):  # iron-strapped battens
        w.box(bm, s - r, s + r, zz - 0.05, zz + 0.05, 0, 0.05, WOOD)
    for i in range(n):
        w.prism(bm, [arc(r, i), arc(r + 0.32, i), arc(r + 0.32, i + 1), arc(r, i + 1)],
                0, 0.12 if i == n // 2 else 0.06 + 0.03 * (i % 2), STONE)
    k = max(2, round((zs - z) / 0.42))
    for j in range(k):
        za, zb = z + (zs - z) * j / k, z + (zs - z) * (j + 1) / k
        wide = 0.4 if j % 2 else 0.28
        w.box(bm, s - r - wide, s - r, za, zb, 0, 0.06 + 0.03 * (j % 2), STONE)
        w.box(bm, s + r, s + r + wide, za, zb, 0, 0.06 + 0.03 * (j % 2), STONE)


def plank_door(bm, w, s, width, height, z):
    """Rectangular plank door in a wooden frame, braced with a Z of battens."""
    w.box(bm, s - width / 2, s + width / 2, z, z + height, -0.06, 0.03, WOOD)
    w.box(bm, s - width / 2 - 0.1, s + width / 2 + 0.1, z + height, z + height + 0.14, 0, 0.14, WOOD)
    for j in (s - width / 2 - 0.1, s + width / 2):
        w.box(bm, j, j + 0.1, z, z + height, 0, 0.12, WOOD)
    for zz in (z + 0.3, z + height - 0.3):
        w.box(bm, s - width / 2, s + width / 2, zz - 0.06, zz + 0.06, 0, 0.06, WOOD)
    w.beam(bm, s - width / 2 + 0.08, z + 0.36, s + width / 2 - 0.08, z + height - 0.36, 0.1, 0, 0.055, WOOD)


def quoins(bm, walls, z0, z1, size=0.4):
    """Corner stones of a block, alternately long on one face and short on the other, z0 to z1."""
    for w in walls:  # each wall's right end; e < 0 runs along the next wall
        for k in range(int((z1 - z0) / size)):
            la, lb = (0.55, 0.3) if k % 2 else (0.3, 0.55)
            z = z0 + k * size
            w.box(bm, w.length - la, w.length + 0.05, z + 0.02, z + size - 0.02, -lb, 0.05, STONE)


def framing(bm, w, z0, z1, panels):
    """Half-timbering on facade `w` from z0 to z1: sill beam, top plate, a rail at window-sill height
    and a post at each panel end. `panels`: (s0, s1, kind), kind "/" or "\\" (a full-height brace),
    "x" (St Andrew's cross under the rail), "w" (a leaded window above the rail) or "" (plain)."""
    zr = z0 + 0.4 * (z1 - z0)
    w.box(bm, -0.06, w.length + 0.06, z0, z0 + 0.22, 0, 0.07, WOOD)
    w.box(bm, -0.06, w.length + 0.06, z1 - 0.2, z1, 0, 0.07, WOOD)
    w.box(bm, 0, w.length, zr, zr + 0.15, 0, 0.05, WOOD)
    for p in sorted({p for s0, s1, _ in panels for p in (s0, s1)}):
        w.box(bm, p - 0.09, p + 0.09, z0, z1, 0, 0.06, WOOD)
    for s0, s1, kind in panels:
        a, b = s0 + 0.09, s1 - 0.09
        if kind == "/" or kind == "\\":
            lo, hi = (a, b) if kind == "/" else (b, a)
            w.beam(bm, lo, z0 + 0.22, hi, z1 - 0.2, 0.15, 0, 0.045, WOOD)
        elif kind == "x":
            w.beam(bm, a, z0 + 0.22, b, zr, 0.13, 0, 0.045, WOOD)
            w.beam(bm, b, z0 + 0.22, a, zr, 0.13, 0, 0.045, WOOD)
        elif kind == "w":
            leaded_window(bm, w, (s0 + s1) / 2, zr + 0.15, b - a - 0.06, z1 - zr - 0.45)


def gable_framing(bm, w, z0, rise, windows=False):
    """Timbers on a gable triangle: rafters along its edges, a king post, a collar and two struts,
    optionally a pair of small attic windows."""
    m, top = w.length / 2, z0 + rise
    for s in (0, w.length):
        w.beam(bm, s, z0, m, top, 0.2, 0, 0.06, WOOD)
    w.box(bm, m - 0.09, m + 0.09, z0, top, 0, 0.06, WOOD)
    zc = z0 + rise * 0.45
    sc = m * 0.45
    w.box(bm, sc, w.length - sc, zc, zc + 0.16, 0, 0.05, WOOD)
    for s in (m * 0.3, w.length - m * 0.3):
        w.beam(bm, s, z0 + 0.1, m, zc, 0.13, 0, 0.045, WOOD)
    if windows:
        for s in (m - 0.6, m + 0.6):
            leaded_window(bm, w, s, zc + 0.3, 0.42, 0.62)


def log_wall(bm, w, z0, z1, openings=(), span=None, ext=(0.3, 0.3), phase=0.0):
    """Horizontal logs on facade `w` from z0 to z1 over s = span (default: the whole wall), running
    `ext` past its ends (the crossed corner joints). Diamond section, so each log shows a lit and a
    shaded face. Cut around `openings` (s0, s1, z0, z1); the wall's core shows behind them."""
    s_lo, s_hi = span or (0, w.length)
    z = z0 + LOG / 2 + phase
    while z < z1 - LOG / 4:
        pieces, s = [], s_lo - ext[0]
        for a, b, oz0, oz1 in sorted(openings):
            if oz0 < z + LOG / 2 and oz1 > z - LOG / 2:
                pieces.append((s, a))
                s = max(s, b)
        pieces.append((s, s_hi + ext[1]))
        for a, b in pieces:
            if b - a > 0.15:
                para(bm, w.at((a + b) / 2, z), w.along * (b - a), Z * LOG / 2 + w.out * 0.09,
                     Z * LOG / 2 - w.out * 0.09, WALL)
        z += LOG


def battens(bm, w, s0, s1, z0, z1, step=0.6, skip=()):
    """Vertical battens over a board wall, every `step`, leaving out the `skip` (s0, s1) spans."""
    s = s0 + step / 2
    while s < s1:
        if not any(a - 0.1 < s < b + 0.1 for a, b in skip):
            w.box(bm, s - 0.05, s + 0.05, z0, z1, 0, 0.04, WOOD)
        s += step


def boarded_gable(bm, w, eave, rise, step=0.85):
    """Gable triangle of vertical boards: battens over a plain triangle."""
    gable(bm, w, eave, rise, WALL)
    m = w.length / 2
    s = step / 2
    while s < w.length:
        top = eave + rise * (1 - abs(s - m) / m)
        if top - eave > 0.3:
            w.box(bm, s - 0.05, s + 0.05, eave, top, 0, 0.04, WOOD)
        s += step


def purlins(bm, x0, x1, span, eave, rise):
    """Chalet roof beams running out past the gables to the roof's edge: wall plates, mid purlins and
    the ridge purlin, tops under the slabs."""
    for f in (-1, -0.5, 0, 0.5, 1):
        y = f * (span / 2 - 0.12)
        top = eave + rise * (1 - abs(y) / (span / 2))
        box(bm, (x0, y - 0.12, top - 0.3), (x1, y + 0.12, top), WOOD)


def barge(bm, x, span, eave, rise, over_side, pitch, teeth=True):
    """Barge boards along both rakes of the gable at x (just inside the roof's edge), with a row of
    carved teeth under them."""
    t = tan(radians(pitch))
    half = span / 2 + over_side
    g = Wall((x, -half, 0), (0, 1, 0), (1 if x > 0 else -1, 0, 0), 2 * half)

    def under(s):  # board's lower edge at s
        return eave - over_side * t + min(s, 2 * half - s) * t - 0.32 / cos(radians(pitch))
    for s0, s1 in ((0, half), (2 * half, half)):
        g.beam(bm, s0, under(s0) + 0.18, s1, under(s1) + 0.18, 0.3, -0.12, -0.06, WOOD)
    if teeth:
        s = 0.25
        while s < 2 * half - 0.2:
            if abs(s - half) > 0.25:
                g.prism(bm, [(s - 0.1, under(s - 0.1) + 0.03), (s + 0.1, under(s + 0.1) + 0.03),
                             (s, under(s) - 0.15)], -0.11, -0.07, WOOD)
            s += 0.45


def balcony(bm, w, s0, s1, z, depth, gap=None, rail=0.95, step=0.38, brackets=None):
    """Wooden balcony (or porch) on facade `w` from s0 to s1, floor top at z, `depth` out: boards,
    balusters alternately wide and narrow (the cut-out look) and hand rails on its three open sides,
    leaving out `gap` (s0, s1) in front for steps; diagonal brackets underneath at the `brackets` s
    positions (default: every ~1.8 m)."""
    w.box(bm, s0, s1, z - 0.12, z, 0, depth, WOOD)
    for a, b in [(s0, s1)] if gap is None else [(s0, gap[0]), (gap[1], s1)]:
        w.box(bm, a, b, z + rail - 0.08, z + rail, depth - 0.1, depth, WOOD)
        w.box(bm, a, b, z + 0.08, z + 0.15, depth - 0.08, depth - 0.02, WOOD)
        n = max(1, round((b - a) / step))
        for i in range(n + 1):
            s, h = a + 0.05 + i * (b - a - 0.1) / n, 0.06 if i % 2 else 0.035
            w.box(bm, s - h, s + h, z, z + rail - 0.08, depth - 0.07, depth - 0.04, WOOD)
    for s in (s0 + 0.05, s1 - 0.05):
        w.box(bm, s - 0.05, s + 0.05, z + rail - 0.08, z + rail, 0, depth, WOOD)
        n = max(2, round(depth / step))
        for i in range(1, n):
            e, h = i * depth / n, 0.06 if i % 2 else 0.035
            w.box(bm, s - 0.015, s + 0.015, z, z + rail - 0.08, e - h, e + h, WOOD)
    if brackets is None:
        k = max(2, round((s1 - s0) / 1.8) + 1)
        brackets = [s0 + 0.15 + i * (s1 - s0 - 0.3) / (k - 1) for i in range(k)]
    for s in brackets:
        w.board(bm, s - 0.06, s + 0.06, (z - 0.8, 0.0), (z - 0.12, depth * 0.75), 0.12, WOOD)


def firewood(bm, w, s0, s1, z0, rows, e0=0.15, depth=0.5):
    """Logs stacked end-out against facade `w` from s0 to s1, `rows` high from z0, on a backing block."""
    n = round((s1 - s0) / 0.4)
    w.box(bm, s0, s1, z0, z0 + rows * 0.36, e0, e0 + depth - 0.05, WOOD)
    for r in range(rows):
        for i in range(n - r % 2):
            s = s0 + (i + 0.5 + 0.5 * (r % 2)) * (s1 - s0) / n
            para(bm, w.at(s, z0 + 0.18 + r * 0.36, e0 + depth / 2), w.out * depth,
                 w.along * 0.2 + Z * 0.18, w.along * 0.2 - Z * 0.18, WOOD)


# --- Medieval -------------------------------------------------------------------------------------

def colombage(bm):
    """house_0: half-timbered house. Stone ground floor with an arched door, upper floor jettied front
    and back over joist ends, posts, braces and St Andrew's crosses, leaded windows, framed gables,
    steep tiled roof, chimney."""
    w, d, h0, h1, jet = 7.6, 6.0, 2.7, 5.1, 0.45
    plinth(bm, -w / 2, w / 2, -d / 2, d / 2)
    box(bm, (-w / 2, -d / 2, PLINTH), (w / 2, d / 2, h0), STONE)
    box(bm, (-w / 2, -d / 2 - jet, h0), (w / 2, d / 2 + jet, h1), WALL)
    rise = roof(bm, -w / 2, w / 2, d + 2 * jet, h1, 50, 0.35, 0.35, 10)
    gf, up = sides(-w / 2, w / 2, -d / 2, d / 2), sides(-w / 2, w / 2, -d / 2 - jet, d / 2 + jet)
    for wall in (gf[0], gf[2]):  # joists carrying the jetty
        for k in range(10):
            s = 0.3 + k * (w - 0.6) / 9
            wall.box(bm, s - 0.08, s + 0.08, h0 - 0.18, h0, 0, jet + 0.06, WOOD)
    long_side = [(0, 1.3, "/"), (1.3, 2.5, "w"), (2.5, 3.8, "x"), (3.8, 5.1, "x"), (5.1, 6.3, "w"), (6.3, 7.6, "\\")]
    framing(bm, up[0], h0, h1, long_side)
    framing(bm, up[2], h0, h1, long_side)
    for wall in (up[1], up[3]):
        framing(bm, wall, h0, h1, [(0, 1.5, "/"), (1.5, 2.7, "w"), (2.7, 4.2, "x"), (4.2, 5.4, "w"), (5.4, 6.9, "\\")])
        gable(bm, wall, h1, rise, WALL)
        gable_framing(bm, wall, h1, rise, windows=wall is up[1])
    arched_door(bm, gf[0], 3.3, 1.1, 2.15)
    for s in (1.4, 5.9):
        leaded_window(bm, gf[0], s, 1.0, 0.8, 0.9, stone_frame=True)
        leaded_window(bm, gf[2], s, 1.0, 0.8, 0.9, stone_frame=True)
    for wall in (gf[1], gf[3]):
        leaded_window(bm, wall, 3.0, 1.1, 0.6, 0.8, stone_frame=True)
    chimney(bm, 2.1, 0.9, h1, h1 + rise + 0.8)


def gable_front(bm):
    """house_1: town house with its gable to the street. Stone ground floor with an arched door and a
    shop window with a fold-down counter and a propped flap, framed upper floor jettied over the
    street, gable jettied again with a hoist beam, steep slate roof. Built door to +X, then turned."""
    L, S, h0, h1, j1, j2 = 8.4, 5.8, 2.6, 4.9, 0.4, 0.3
    plinth(bm, -L / 2, L / 2, -S / 2, S / 2)
    box(bm, (-L / 2, -S / 2, PLINTH), (L / 2, S / 2, h0), STONE)
    box(bm, (-L / 2, -S / 2, h0), (L / 2 + j1, S / 2, h1), WALL)
    xg = L / 2 + j1 + j2
    rise = roof(bm, -L / 2, xg, S, h1, 55, 0.3, 0.3, 11)
    gf, up = sides(-L / 2, L / 2, -S / 2, S / 2), sides(-L / 2, L / 2 + j1, -S / 2, S / 2)
    front = Wall((xg, -S / 2, 0), (0, 1, 0), (1, 0, 0), S)
    gable(bm, front, h1, rise, WALL, depth=j2 + 0.3)
    gable(bm, up[3], h1, rise, WALL)
    for k in range(9):  # joists under both jetties
        s = 0.3 + k * (S - 0.6) / 8
        gf[1].box(bm, s - 0.08, s + 0.08, h0 - 0.18, h0, 0, j1 + 0.06, WOOD)
        up[1].box(bm, s - 0.08, s + 0.08, h1 - 0.16, h1, 0, j2 + 0.06, WOOD)
    framing(bm, up[1], h0, h1, [(0, 1.0, "/"), (1.0, 2.3, "w"), (2.3, 3.5, "x"), (3.5, 4.8, "w"), (4.8, 5.8, "\\")])
    framing(bm, up[3], h0, h1, [(0, 1.5, "/"), (1.5, 2.9, "w"), (2.9, 4.3, "x"), (4.3, 5.8, "\\")])
    for wall in (up[0], up[2]):
        framing(bm, wall, h0, h1, [(0, 1.4, "/"), (1.4, 2.6, "w"), (2.6, 4.4, "x"), (4.4, 5.6, "w"),
                                   (5.6, 7.2, "x"), (7.2, 8.8, "\\")])
    gable_framing(bm, front, h1, rise, windows=True)
    gable_framing(bm, up[3], h1, rise)
    front.board(bm, S / 2 - 0.08, S / 2 + 0.08, (h1 + rise - 1.0, -0.3), (h1 + rise - 1.0, 0.9), 0.16, WOOD)  # hoist beam
    arched_door(bm, gf[1], 1.8, 1.1, 2.15)
    leaded_window(bm, gf[1], 4.2, 0.9, 1.4, 1.1)  # shop window
    gf[1].box(bm, 3.4, 5.0, 0.78, 0.87, 0, 0.6, WOOD)  # counter, folded down…
    for s in (3.6, 4.8):
        gf[1].board(bm, s - 0.04, s + 0.04, (0.35, 0.0), (0.8, 0.5), 0.07, WOOD)
    gf[1].board(bm, 3.4, 5.0, (2.05, 0.02), (2.4, 0.62), 0.06, WOOD)  # …and the flap propped up above
    for wall in (gf[0], gf[2]):
        leaded_window(bm, wall, 5.0, 1.0, 0.7, 0.9, stone_frame=True)
    leaded_window(bm, gf[3], 2.9, 1.0, 0.7, 0.9, stone_frame=True)
    chimney(bm, -2.6, 0.75, h1, h1 + rise + 0.6)
    turn(bm, -pi / 2)


def manor(bm):
    """house_2: stone house. Stone ground floor, rendered upper floor with stone quoins, a string
    course, stone-cross windows, a big arched door, a dormer, and a round stair tower with a conical
    roof at the back corner."""
    w, d, h0, h1 = 8.0, 6.2, 2.6, 5.0
    plinth(bm, -w / 2, w / 2, -d / 2, d / 2)
    box(bm, (-w / 2, -d / 2, PLINTH), (w / 2, d / 2, h0), STONE)
    box(bm, (-w / 2, -d / 2, h0), (w / 2, d / 2, h1), WALL)
    rise = roof(bm, -w / 2, w / 2, d, h1, 50, 0.35, 0.3, 9)
    ws = sides(-w / 2, w / 2, -d / 2, d / 2)
    for wall in (ws[1], ws[3]):
        gable(bm, wall, h1, rise, WALL)
    quoins(bm, ws, h0 + 0.12, h1)
    for wall in ws:  # string course between the floors
        wall.box(bm, -0.08, wall.length + 0.08, h0 - 0.04, h0 + 0.14, 0, 0.1, STONE)
    arched_door(bm, ws[0], 3.2, 1.3, 2.45)
    for s in (1.2, 5.8):
        leaded_window(bm, ws[0], s, 1.0, 1.0, 1.15, True, STONE)
    for s in (1.2, 3.2, 5.8):
        leaded_window(bm, ws[0], s, 3.2, 0.9, 1.2, True, STONE)
    for s in (2.0, 5.6):
        for z in (1.0, 3.2):
            leaded_window(bm, ws[2], s, z, 0.9, 1.15, True, STONE)
    for wall in (ws[1], ws[3]):
        leaded_window(bm, wall, 3.1, 3.3, 0.7, 1.0, True, STONE)
    leaded_window(bm, ws[3], 3.1, 1.1, 0.7, 0.9, True, STONE)
    # Dormer on the front slope: walls, gable and a little roof of its own (ridge turned along Y).
    box(bm, (-0.7, -2.8, 5.3), (0.7, -0.9, 6.6), WALL)
    dw = Wall((-0.7, -2.8, 0), (1, 0, 0), (0, -1, 0), 1.4)
    old = set(bm.verts)
    drise = roof(bm, -2.8, -0.9, 1.4, 6.6, 50, 0.12, 0.12, 3, thick=0.12)
    turn(bm, pi / 2, [v for v in bm.verts if v not in old])
    gable(bm, dw, 6.6, drise, WALL, depth=0.2)
    leaded_window(bm, dw, 0.7, 5.75, 0.6, 0.65)
    # Round tower at the back right corner, on its own plinth.
    c = Vector((3.3, 2.5, 0))
    prism(bm, ring(c - Z * 1.5, 1.75), Z * (1.5 + PLINTH), STONE)
    prism(bm, ring(c + Z * PLINTH, 1.6), Z * (7.7 - PLINTH), STONE)
    prism(bm, ring(c + Z * 7.25, 1.75), Z * 0.45, STONE)  # corbelled top
    cone(bm, c + Z * 7.7, 2.0, 4.0, ROOF)
    for a, z in ((-0.35, 2.0), (0.4, 4.6), (1.2, 3.3), (-0.35, 5.6)):  # arrow slits facing out
        r = Vector((cos(a), sin(a), 0))
        para(bm, c + r * 1.6 + Z * z, Vector((-r.y, r.x, 0)) * 0.14, Z * 0.75, r * 0.12, GLASS)
    chimney(bm, -2.9, 0.6, h1, h1 + rise + 0.5)


# --- Chalets --------------------------------------------------------------------------------------

def log_facade(bm, w, z0, z1, windows, door=None, **logs):
    """Log wall on facade `w` from z0 to z1 with its `windows` (s, z, width, height; glazed doors when
    taller than 1.5 m) and an optional plank `door` (same tuple). `logs`: span/ext/phase of log_wall."""
    cuts = [(s - wd / 2 - 0.05, s + wd / 2 + 0.05, z, z + ht) for s, z, wd, ht in windows + ([door] if door else [])]
    log_wall(bm, w, z0, z1, cuts, **logs)
    for s, z, wd, ht in windows:
        chalet_window(bm, w, s, z, wd, ht, sill=ht < 1.5)
    if door:
        plank_door(bm, w, door[0], door[2], door[3], door[1])


def chalet(bm):
    """house_3: chalet with its gable to the front. Stone ground floor, log upper floor with crossed
    corner joints, boarded gables, wide low roof on purlins with carved barge boards, a balcony across
    the front and a smaller one in the gable, shuttered windows. Built door to +X, then turned."""
    L, S, h0, h1 = 9.0, 8.0, 2.6, 5.0
    pitch, over_side, over_gable = 24, 1.2, 1.4
    plinth(bm, -L / 2, L / 2, -S / 2, S / 2)
    box(bm, (-L / 2, -S / 2, PLINTH), (L / 2, S / 2, h0), STONE)
    box(bm, (-L / 2, -S / 2, h0), (L / 2, S / 2, h1), WALL)
    rise = roof(bm, -L / 2, L / 2, S, h1, pitch, over_side, over_gable, 8)
    purlins(bm, -L / 2 - over_gable + 0.1, L / 2 + over_gable - 0.1, S, h1, rise)
    barge(bm, L / 2 + over_gable, S, h1, rise, over_side, pitch)
    barge(bm, -L / 2 - over_gable, S, h1, rise, over_side, pitch, teeth=False)
    ws = sides(-L / 2, L / 2, -S / 2, S / 2)
    front = ws[1]
    for wall in (ws[1], ws[3]):
        boarded_gable(bm, wall, h1, rise)
    log_facade(bm, front, h0, h1, [(2.0, h0 + 0.15, 0.9, 1.9), (6.0, h0 + 0.15, 0.9, 1.9)], phase=LOG / 2)
    for wall in (ws[0], ws[2]):
        log_facade(bm, wall, h0, h1, [(2.5, 3.1, 0.9, 1.1), (6.5, 3.1, 0.9, 1.1)])
    log_facade(bm, ws[3], h0, h1, [(4.0, 3.1, 0.9, 1.1)], phase=LOG / 2)
    plank_door(bm, front, 3.0, 1.0, 2.1, PLINTH)
    chalet_window(bm, front, 5.6, 1.1, 0.7, 0.8, shutter_e=0.0)
    balcony(bm, front, -0.45, S + 0.45, h0 + 0.12, 1.3, brackets=[-0.3, 1.5, 4.5, 6.3, 8.3])  # clear of the door
    balcony(bm, front, S / 2 - 1.7, S / 2 + 1.7, h1 + 0.25, 0.9, rail=0.85)
    chalet_window(bm, front, S / 2, h1 + 0.3, 0.8, 1.1, sill=False)  # door onto the gable balcony
    chimney(bm, -2.2, 1.3, h1 - 0.5, h1 + rise + 0.6)
    turn(bm, -pi / 2)


def farmhouse(bm):
    """house_4: long Alpine farmhouse. Living quarters on the right (stone ground floor, logs above,
    a balcony over the door), a boarded barn on the left with a big braced double door and a hay loft
    door, one wide low roof over both."""
    w, d, base, h = 12.0, 7.4, 0.5, 5.0
    pitch, over_side, over_gable = 22, 1.3, 1.0
    plinth(bm, -w / 2, w / 2, -d / 2, d / 2, top=base)
    box(bm, (-w / 2, -d / 2, base), (0, d / 2, h), WALL)
    box(bm, (0, -d / 2, base), (w / 2, d / 2, 2.6), STONE)
    box(bm, (0, -d / 2, 2.6), (w / 2, d / 2, h), WALL)
    rise = roof(bm, -w / 2, w / 2, d, h, pitch, over_side, over_gable, 8)
    purlins(bm, -w / 2 - over_gable + 0.1, w / 2 + over_gable - 0.1, d, h, rise)
    barge(bm, w / 2 + over_gable, d, h, rise, over_side, pitch)
    barge(bm, -w / 2 - over_gable, d, h, rise, over_side, pitch, teeth=False)
    ws = sides(-w / 2, w / 2, -d / 2, d / 2)
    for wall in (ws[1], ws[3]):
        boarded_gable(bm, wall, h, rise)
    # Living quarters, x 0..6 (s 6..12 of the front, the right wall, s 0..6 of the back): stone
    # ground floor, logs above.
    plank_door(bm, ws[0], 7.0, 1.0, 2.0, base)
    for wall, s in ((ws[0], 9.3), (ws[0], 11.0), (ws[1], 1.8)):
        chalet_window(bm, wall, s, 1.3, 0.8, 0.9, shutter_e=0.0)
    log_facade(bm, ws[0], 2.6, h, [(8.0, 2.8, 0.9, 1.8), (10.6, 2.8, 0.9, 1.8)], span=(6, 12), ext=(0, 0.3))
    log_facade(bm, ws[1], 2.6, h, [(1.8, 3.1, 0.8, 1.0), (5.0, 3.1, 0.8, 1.0)], phase=LOG / 2)
    log_facade(bm, ws[2], 2.6, h, [(2.0, 3.1, 0.8, 1.0), (4.4, 3.1, 0.8, 1.0)], span=(0, 6), ext=(0.3, 0))
    for wall in (ws[0], ws[2]):  # posts where the living quarters meet the barn's boards
        wall.box(bm, 5.88, 6.12, base, h, 0, 0.13, WOOD)
    # Barn, x -6..0: boards with battens, double door with a hay loft door above.
    battens(bm, ws[0], 0, 6, base, h, skip=[(1.5, 4.5)])
    battens(bm, ws[2], 6, 12, base, h)
    battens(bm, ws[3], 0, d, base, h)
    for s0, s1 in ((1.6, 3.0), (3.0, 4.4)):
        ws[0].box(bm, s0 + 0.02, s1 - 0.02, base, 3.4, 0, 0.05, WOOD)
        ws[0].beam(bm, s0 + 0.12, base + 0.3, s1 - 0.12, 3.1, 0.14, 0.05, 0.09, WOOD)
        for z in (base + 0.25, 3.15):
            ws[0].box(bm, s0 + 0.02, s1 - 0.02, z - 0.07, z + 0.07, 0.05, 0.09, WOOD)
    ws[0].box(bm, 1.45, 4.55, 3.4, 3.55, 0, 0.12, WOOD)
    plank_door(bm, ws[0], 3.0, 1.0, 0.9, 3.75)
    balcony(bm, ws[0], 6.25, 11.9, 2.75, 1.1, brackets=[6.4, 8.0, 9.9, 11.75])
    chimney(bm, 3.0, 1.2, h - 0.5, h + rise + 0.6)


def mazot(bm):
    """house_5: small chalet with its gable to the front. Logs with crossed corners on a high stone
    base, a deep roof over a railed porch reached by wooden steps, carved barge boards, firewood along
    the side. Built door to +X, then turned."""
    L, S, base, h = 6.6, 5.8, 0.9, 3.5
    pitch, over_side, over_gable, porch = 28, 1.1, 1.0, 1.4
    plinth(bm, -L / 2, L / 2, -S / 2, S / 2, top=base)
    box(bm, (-L / 2, -S / 2, base), (L / 2, S / 2, h), WALL)
    rise = roof(bm, -L / 2, L / 2 + 0.6, S, h, pitch, over_side, over_gable, 7)  # 1.6 m over the porch
    purlins(bm, -L / 2 - over_gable + 0.1, L / 2 + 0.6 + over_gable - 0.1, S, h, rise)
    barge(bm, L / 2 + 0.6 + over_gable, S, h, rise, over_side, pitch)
    barge(bm, -L / 2 - over_gable, S, h, rise, over_side, pitch, teeth=False)
    ws = sides(-L / 2, L / 2, -S / 2, S / 2)
    for wall in (ws[1], ws[3]):
        boarded_gable(bm, wall, h, rise)
    log_facade(bm, ws[1], base, h, [(4.3, 1.75, 0.8, 0.9)], door=(2.0, base, 0.95, 2.0))
    log_facade(bm, ws[0], base, h, [(3.3, 1.75, 0.8, 0.9)], phase=LOG / 2)
    log_facade(bm, ws[2], base, h, [(2.0, 1.75, 0.8, 0.9), (4.6, 1.75, 0.8, 0.9)], phase=LOG / 2)
    log_facade(bm, ws[3], base, h, [(2.9, 1.75, 0.8, 0.9)])
    chalet_window(bm, ws[1], S / 2, h + 0.2, 0.7, 0.75)  # in the gable
    balcony(bm, ws[1], -0.45, S + 0.45, base, porch, gap=(1.45, 2.55), rail=0.9, brackets=[])
    for s in (-0.35, 1.35, 2.65, S + 0.35):  # deck posts
        ws[1].box(bm, s - 0.07, s + 0.07, 0, base - 0.12, porch - 0.2, porch - 0.06, WOOD)
    for k in range(3):  # steps down from the porch
        ws[1].box(bm, 1.45, 2.55, 0, base - (k + 1) * base / 4, porch + 0.3 * k, porch + 0.3 * (k + 1), WOOD)
    firewood(bm, ws[0], 1.4, 5.0, 0, 3)
    chimney(bm, -1.6, -1.0, h - 0.5, h + rise + 0.6)
    turn(bm, -pi / 2)


def build(name, fn, palette):
    bm = bmesh.new()
    fn(bm)
    assert {f.material_index for f in bm.faces} == set(range(5)), name + ": empty material slot"
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Face order out of bmesh ops varies between runs and the exporter keeps it as triangle order:
    # triangulate and sort by position so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    for f in bm.faces:
        f.smooth = False
    bake_shade(bm, 2.5, strength=0.5, base=0.85)  # reach: under the eaves and balconies
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    xs, ys, zs = ([v.co[i] for v in bm.verts] for i in range(3))
    print(f"{name}: {len(bm.faces)} triangles, {max(xs) - min(xs):.1f} x {max(ys) - min(ys):.1f} m, "
          f"{max(zs):.1f} m tall")
    bm.free()
    for i, slot in enumerate(("wall", "roof", "wood", "glass", "stone")):
        mesh.materials.append(material(f"{name}_{slot}", palette[i], 0.4 if i == GLASS else 0.9))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    export(obj, os.path.join(OUT, name + ".glb"))


if __name__ == "__main__":  # tools/make_cabins.py imports the helpers above
    bpy.ops.wm.read_factory_settings(use_empty=True)
    os.makedirs(OUT, exist_ok=True)
    # Palette names: walls, roof, wood, glass, stone.
    build("house_0", colombage, ["cream", "terracotta", "bark", "ink", "stone"])
    build("house_1", gable_front, ["sand", "slate", "bark", "ink", "stone"])
    build("house_2", manor, ["snow", "terracotta", "bark", "ink", "stone"])
    build("house_3", chalet, ["ochre", "slate", "bark", "ink", "stone"])
    build("house_4", farmhouse, ["ochre", "terracotta", "bark", "ink", "stone"])
    build("house_5", mazot, ["ochre", "slate", "bark", "ink", "stone"])
