extends TextureRect
## Top-down map toggled with M, centred on the player. Zones not generated yet are hidden under clouds.

const RADIUS := 6  # zones shown on each side of the player's zone
const REFRESH := 0.25  # seconds between redraws while open

# Landmark glyphs (world.Landmark order): '#' = fill; the pixels round them (and holes) get a dark rim.
const GLYPHS := [
	["#.#.#", "#####", ".###.", ".###.", ".#.#.", ".###.", "#####"],  # ruined tower
	["#...#", ".#.#.", "..#..", ".#.#.", "#.#.#", ".###.", ".###."],  # windmill
	["#######", "#######", "##...##", "#.....#"],  # bridge
	["..#..", ".###.", "..#..", ".###.", "#####", ".#.#.", ".###."],  # chapel
	[".#.#.", "#...#", ".....", "#...#", ".#.#."],  # standing stones
]
const GLYPH_COLOURS := ["limestone", "cream", "stone", "gold", "ash"]

var world: Node3D
var clouds := FastNoiseLite.new()
var _since := 0.0
var names: Array[Label] = []  # village name labels, reused between refreshes


func _init() -> void:
	visible = false
	set_anchors_preset(PRESET_FULL_RECT)
	expand_mode = EXPAND_IGNORE_SIZE
	stretch_mode = STRETCH_KEEP_ASPECT_CENTERED
	mouse_filter = MOUSE_FILTER_IGNORE
	clouds.frequency = 0.004  # cloud puffs ~250 m across
	clouds.fractal_octaves = 3


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_M:
		visible = not visible
		if visible:
			refresh()


func _process(delta: float) -> void:
	_since += delta
	if visible and _since >= REFRESH:
		refresh()


func refresh() -> void:
	_since = 0.0
	var px: int = world.MAP_PX
	var zs: int = world.ZONE_SIZE
	var m_per_px := float(zs) / px
	var cells := 2 * RADIUS + 1
	var size := cells * px
	var first: Vector2i = world.cell_of(world.player.global_position) - Vector2i.ONE * RADIUS
	var corner := (Vector2(first) - Vector2.ONE * 0.5) * zs  # world x/z of the map's top-left pixel

	# Clouds everywhere, computed at 1/4 resolution then smoothed up (cheap and fluffy).
	var low := Image.create(size / 4, size / 4, false, Image.FORMAT_RGB8)
	for y in low.get_height():
		for x in low.get_width():
			var w := corner + Vector2(x, y) * 4.0 * m_per_px
			var v := clouds.get_noise_2d(w.x, w.y) * 0.5 + 0.5
			low.set_pixel(x, y, Color(0.72, 0.75, 0.82).lerp(Color(0.98, 0.98, 1.0), v))
	low.resize(size, size, Image.INTERPOLATE_BILINEAR)
	var img := low

	# Generated zones on top.
	for cy in cells:
		for cx in cells:
			var tile: Image = world.map_tiles.get(first + Vector2i(cx, cy))
			if tile:
				img.blit_rect(tile, Rect2i(0, 0, px, px), Vector2i(cx, cy) * px)

	# Landmarks (generated zones only): a pale glyph per kind with a dark rim; village names as labels.
	var lg: float = world.LANDMARK_GRID
	for gx in range(floori(corner.x / lg), floori((corner.x + size * m_per_px) / lg) + 1):
		for gy in range(floori(corner.y / lg), floori((corner.y + size * m_per_px) / lg) + 1):
			var s: Dictionary = world.landmark_site(Vector2i(gx, gy))
			if not s.is_empty() and world.map_tiles.has(world.cell_of(s.pos)):
				_glyph(img, Vector2i((Vector2(s.pos.x, s.pos.z) - corner) / m_per_px), GLYPHS[s.kind],
					world.seasons.colour(GLYPH_COLOURS[s.kind]))
	var used := 0
	var vg: float = world.VILLAGE_GRID
	var k := minf(self.size.x, self.size.y) / size  # screen px per map px (keep-aspect, centred)
	var offset := (self.size - Vector2.ONE * size * k) / 2.0
	for gx in range(floori(corner.x / vg), floori((corner.x + size * m_per_px) / vg) + 1):
		for gy in range(floori(corner.y / vg), floori((corner.y + size * m_per_px) / vg) + 1):
			var site: Dictionary = world.village_site(Vector2i(gx, gy))
			if site.is_empty() or not world.map_tiles.has(world.cell_of(Vector3(site.centre.x, 0, site.centre.y))):
				continue
			if used == names.size():
				var l := Label.new()
				l.add_theme_font_size_override("font_size", 14)
				l.add_theme_constant_override("outline_size", 5)
				l.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.75))
				l.add_theme_color_override("font_color", Color(0.24, 0.21, 0.22))
				add_child(l)
				names.append(l)
			var l: Label = names[used]
			l.text = world.village(Vector2i(gx, gy)).name
			l.reset_size()
			l.position = offset + (site.centre - corner) / m_per_px * k - Vector2(l.size.x / 2.0, l.size.y + 6.0)
			l.visible = true
			used += 1
	for i in range(used, names.size()):
		names[i].visible = false

	# Player: red dot plus a short line in the facing direction.
	var p: Vector3 = world.player.global_position
	var at := (Vector2(p.x, p.z) - corner) / m_per_px
	var f: Vector3 = -world.player.global_basis.z
	for i in 9:
		var q := Vector2i(at + Vector2(f.x, f.z) * i)
		if Rect2i(Vector2i.ZERO, img.get_size()).has_point(q):
			img.set_pixelv(q, Color(0.85, 0.1, 0.1))
	img.fill_rect(Rect2i(Vector2i(at) - Vector2i(2, 2), Vector2i(5, 5)), Color(0.85, 0.1, 0.1))
	texture = ImageTexture.create_from_image(img)
	# North up, except in iso view: turned like the iso camera so the map's up is the screen's up.
	var pl = world.player
	pivot_offset = self.size / 2.0
	rotation = pl.ISO_YAW if pl.view == pl.View.ISO else 0.0


## Draws `glyph` centred on `at`: fill colour on '#', a dark rim on every other pixel touching one.
static func _glyph(img: Image, at: Vector2i, glyph: Array, fill: Color) -> void:
	var h := glyph.size()
	var w: int = glyph[0].length()
	var o := at - Vector2i(w / 2, h / 2)
	var on := func(x: int, y: int) -> bool: return x >= 0 and y >= 0 and x < w and y < h and glyph[y][x] == "#"
	for y in range(-1, h + 1):
		for x in range(-1, w + 1):
			var q := o + Vector2i(x, y)
			if not Rect2i(Vector2i.ZERO, img.get_size()).has_point(q):
				continue
			if on.call(x, y):
				img.set_pixelv(q, fill)
			elif on.call(x - 1, y) or on.call(x + 1, y) or on.call(x, y - 1) or on.call(x, y + 1):
				img.set_pixelv(q, Color(0.24, 0.21, 0.22))
