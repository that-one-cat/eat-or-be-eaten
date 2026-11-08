extends SceneTree
## Bakes res://shaders/textures/caustics_cells.png: a tileable (periodic) Voronoi "F2 - F1" cell-edge map used by
## water_caustics.gdshaderinc (0 on the cell borders, rising inside the cells). Deterministic (fixed seed); rerun only to
## change the pattern:
##   godot --headless --path game --script res://shaders/gen_caustics.gd
## then `godot --headless --path game --import`.

const SIZE: int = 256
const CELLS: int = 7
const SEED: int = 5101
const OUT_PATH: String = "res://shaders/textures/caustics_cells.png"


func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var pts := PackedVector2Array()
	pts.resize(CELLS * CELLS)
	for j in CELLS:
		for i in CELLS:
			pts[j * CELLS + i] = Vector2(float(i) + rng.randf_range(0.1, 0.9), float(j) + rng.randf_range(0.1, 0.9))
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_L8)
	var scale: float = float(CELLS) / float(SIZE)
	var max_d: float = 0.0
	var vals := PackedFloat32Array()
	vals.resize(SIZE * SIZE)
	for y in SIZE:
		for x in SIZE:
			var p := Vector2((float(x) + 0.5) * scale, (float(y) + 0.5) * scale)
			var ci: int = int(p.x)
			var cj: int = int(p.y)
			var f1: float = INF
			var f2: float = INF
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var gi: int = ci + di
					var gj: int = cj + dj
					var q: Vector2 = pts[posmod(gj, CELLS) * CELLS + posmod(gi, CELLS)]
					q += Vector2(float(gi - posmod(gi, CELLS)), float(gj - posmod(gj, CELLS)))
					var d: float = p.distance_to(q)
					if d < f1:
						f2 = f1
						f1 = d
					elif d < f2:
						f2 = d
			var v: float = f2 - f1
			vals[y * SIZE + x] = v
			max_d = maxf(max_d, v)
	for y in SIZE:
		for x in SIZE:
			var v: float = clampf(vals[y * SIZE + x] / max_d, 0.0, 1.0)
			img.set_pixel(x, y, Color(v, v, v))
	var err: Error = img.save_png(ProjectSettings.globalize_path(OUT_PATH))
	print("gen_caustics: %s -> %s" % [OUT_PATH, error_string(err)])
	quit(0 if err == OK else 1)
