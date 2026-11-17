"""Generate three low-poly village houses (cottage, long house, two-storey house) as .glb files for Godot.

Run:  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/make_houses.py
Then: godot --headless --path . --import

Each house is boxes and a gable-roof prism, flat shaded. Materials in slot order: walls, roof, wood
(door, shutters), windows, stone plinth. Origin at the footprint centre on the ground; the plinth goes
1.5 m below y=0 so the house sits on uneven ground without gaps. The ridge runs along X; the door is
on the -Y side in Blender (+Z in Godot). No randomness, so re-running gives the same files.
"""
import os

import bmesh
import bpy
from mathutils import Matrix, Vector

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "houses")
WALL, ROOF, WOOD, GLASS, STONE = range(5)


def linear(srgb):
    """Blender/glTF colours are linear; the palette below is picked in sRGB like the rest of the game."""
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def material(name, srgb):
    m = bpy.data.materials.new(name)
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*linear(srgb), 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    return m


def box(bm, lo, hi, mat):
    """Axis-aligned box from corner `lo` to corner `hi`."""
    lo, hi = Vector(lo), Vector(hi)
    m = Matrix.Translation((lo + hi) / 2) @ Matrix.Diagonal((*(hi - lo), 1))
    res = bmesh.ops.create_cube(bm, size=1.0, matrix=m)
    for f in {f for v in res["verts"] for f in v.link_faces}:
        f.material_index = mat


def gable_roof(bm, w, d, wall_h, rise, over):
    """Closed roof prism over a w x d footprint, ridge along X, overhanging by `over`,
    plus the two wall-coloured gable triangles under it."""
    x, y, z0, z1 = w / 2 + over, d / 2 + over, wall_h - 0.15, wall_h + rise
    v = [bm.verts.new(p) for p in [(-x, -y, z0), (x, -y, z0), (x, y, z0), (-x, y, z0), (-x, 0, z1), (x, 0, z1)]]
    for idx in [(0, 1, 5, 4), (2, 3, 4, 5), (0, 4, 3), (1, 2, 5), (0, 3, 2, 1)]:
        bm.faces.new([v[i] for i in idx]).material_index = ROOF
    gx, gy = w / 2, d / 2
    for sx in (-1, 1):  # gable: a thin wedge so it is a closed solid like everything else
        a, b = gx * sx, (gx - 0.1) * sx
        g = [bm.verts.new(p) for p in [(a, -gy, wall_h), (a, gy, wall_h), (a, 0, wall_h + rise - 0.2),
                                       (b, -gy, wall_h), (b, gy, wall_h), (b, 0, wall_h + rise - 0.2)]]
        for idx in [(0, 1, 2), (3, 5, 4), (0, 3, 4, 1), (1, 4, 5, 2), (2, 5, 3, 0)]:
            bm.faces.new([g[i] for i in idx]).material_index = WALL


def house(bm, w, d, wall_h, rise, door_x, windows, chimney=None, floors=1):
    """`windows`: x positions along both long sides; each floor gets a row."""
    box(bm, (-w / 2 - 0.15, -d / 2 - 0.15, -1.5), (w / 2 + 0.15, d / 2 + 0.15, 0.35), STONE)
    box(bm, (-w / 2, -d / 2, 0.35), (w / 2, d / 2, wall_h), WALL)
    gable_roof(bm, w, d, wall_h, rise, 0.45)
    box(bm, (door_x - 0.5, -d / 2 - 0.06, 0.35), (door_x + 0.5, -d / 2 + 0.05, 2.35), WOOD)
    storey = (wall_h - 0.35) / floors
    for f in range(floors):
        z = 0.35 + storey * f + storey * 0.45
        for wx in windows:
            for side in (-1, 1):
                if f == 0 and side == -1 and abs(wx - door_x) < 1.2:
                    continue  # no window over the door
                yo = side * (d / 2 + 0.06)
                yi = side * (d / 2 - 0.05)
                box(bm, (wx - 0.45, min(yo, yi), z), (wx + 0.45, max(yo, yi), z + 0.9), GLASS)
                for sx in (-1, 1):  # shutters
                    box(bm, (wx + sx * 0.45 - (0.3 if sx < 0 else 0), min(yo, yi) - 0.02, z),
                        (wx + sx * 0.45 + (0.3 if sx > 0 else 0), max(yo, yi) + 0.02, z + 0.9), WOOD)
    if chimney is not None:
        box(bm, (chimney - 0.35, 0.3, wall_h), (chimney + 0.35, 1.0, wall_h + rise + 0.6), STONE)


def cottage(bm):
    house(bm, 6.0, 5.0, 2.8, 2.2, -0.8, [-1.9, 1.6], chimney=1.8)


def long_house(bm):
    house(bm, 10.0, 5.5, 2.6, 2.4, 0.0, [-3.6, -1.8, 1.8, 3.6], chimney=-3.2)


def two_storey(bm):
    house(bm, 6.5, 6.0, 5.4, 2.6, 0.0, [-1.8, 1.8], floors=2, chimney=2.2)


def build(name, fn, wall, roof):
    bm = bmesh.new()
    fn(bm)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Face order out of bmesh ops varies between runs and the exporter keeps it as triangle order:
    # triangulate and sort by position so the files come out byte-identical.
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    rank = {f: i for i, f in enumerate(sorted(
        bm.faces, key=lambda f: (f.material_index, *(round(c, 5) for v in f.verts for c in v.co))))}
    bm.faces.sort(key=rank.__getitem__)
    for f in bm.faces:
        f.smooth = False
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    xs, ys, zs = ([v.co[i] for v in bm.verts] for i in range(3))
    print(f"{name}: {len(bm.faces)} triangles, {max(xs) - min(xs):.1f} x {max(ys) - min(ys):.1f} m, "
          f"{max(zs):.1f} m tall")
    bm.free()
    for slot, colour in [("wall", wall), ("roof", roof), ("wood", (0.36, 0.24, 0.15)),
                         ("glass", (0.2, 0.26, 0.32)), ("stone", (0.52, 0.5, 0.47))]:
        mesh.materials.append(material(f"{name}_{slot}", colour))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, name + ".glb"), export_format="GLB",
                              use_selection=True, export_yup=True)


bpy.ops.wm.read_factory_settings(use_empty=True)
os.makedirs(OUT, exist_ok=True)
build("house_0", cottage, (0.9, 0.86, 0.75), (0.62, 0.27, 0.18))
build("house_1", long_house, (0.92, 0.9, 0.85), (0.34, 0.35, 0.4))
build("house_2", two_storey, (0.86, 0.73, 0.52), (0.7, 0.38, 0.22))
