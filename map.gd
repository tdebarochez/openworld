extends TextureRect
## Top-down map toggled with M, centred on the player. Zones not generated yet are hidden under clouds.

const RADIUS := 6  # zones shown on each side of the player's zone
const REFRESH := 0.25  # seconds between redraws while open

var world: Node3D
var clouds := FastNoiseLite.new()
var _since := 0.0


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
