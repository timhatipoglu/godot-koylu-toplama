extends Node3D
## RTS kaynak toplama demosu. Her şey Godot ilkel mesh'leriyle kodda kurulur (dış varlık yok).
## Oyuncu girdisi: sol tık / sol sürükle = köylü seç, sağ tık kaynağa = gönder, sağ tık zemine = yürü,
## "Boşta köylü" düğmesi ya da "." = sıradaki boştaki köylüyü seç, K = imleç altına kereste kampı kur.
## Komut satırı: `-- --auto-rts` (kayıt sürücüsü), `--camp` (sürücü önce kamp kurar),
## `--summary-at=<sn>` (ölçüm özeti zamanı), `--log-every=<sn>` (sayaç satırı aralığı).

const VillagerScript := preload("res://villager.gd")
const ResScript := preload("res://res_node.gd")
const FLAT := preload("res://flat.gdshader")
const KIND_TR := {"wood": "odun", "stone": "taş", "food": "yiyecek"}
const KIND_COL := {"wood": Color(0.80, 0.55, 0.30), "stone": Color(0.75, 0.78, 0.82), "food": Color(0.95, 0.40, 0.40)}
const TUNIC := Color(0.18, 0.42, 0.85)
const CAMP_POS := Vector3(6.3, 0, -0.6)

var t := 0.0
var stock := {"wood": 0, "stone": 0, "food": 0}
var villagers: Array = []
var resources: Array = []
var dropoffs: Array = []
var selection: Array = []
var camera: Camera3D
var caption := ""
var caption_t := 0.0
var summary_at := 9.9
var log_every := 1.0
var _next_log := 0.0
var _summary_done := false
var _mats := {}
var _idle_cycle := 0
var mouse_events_in := 0
var auto_mode := false
var foreign_blocked := 0
const DRIVER_DEVICE := 77   # auto_rts.gd olaylarına bu cihaz numarasını verir
var _wall0 := 0

# arayüz
var hud: Control
var overlay: Control
var lbl_res := {}
var lbl_time: Label
var lbl_sel: Label
var lbl_cap: Label
var btn_idle: Button
var _drag := false
var _drag_a := Vector2.ZERO
var _drag_b := Vector2.ZERO
var cursor_pos := Vector2(-100, -100)
var pings: Array = []     # [pos, t0, color]


func _ready() -> void:
	_wall0 = Time.get_ticks_usec()
	auto_mode = "--auto-rts" in OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		get_window().size = Vector2i(1080, 1080)   # headless pencere 64×64 açılıyor; ekran hesapları 1080 ister
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--summary-at="):
			summary_at = float(a.split("=")[1])
		elif a.begins_with("--log-every="):
			log_every = float(a.split("=")[1])
	_build_world()
	_build_hud()
	print("[sahne] 0.00 sn: köylü %d, ağaç %d (toplam odun %d), taş ocağı %d, teslim yeri %d · pencere %s, viewport %s"
		% [villagers.size(), _count_kind("wood"), _sum_kind("wood"), _count_kind("stone"), dropoffs.size(),
			str(DisplayServer.window_get_size()), str(get_viewport().get_visible_rect().size)])
	print("[sahne] 0.00 sn: viewport → pencere dönüşümü %s" % str(get_viewport().get_final_transform()))


# ---------------------------------------------------------------- yardımcılar
func flat_mat(c: Color) -> ShaderMaterial:
	var key := c.to_html()
	if not _mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = FLAT
		m.set_shader_parameter("albedo", c)
		_mats[key] = m
	return _mats[key]


func mesh(parent: Node3D, m: Mesh, c: Color, pos: Vector3, rot := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = flat_mat(c)
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	parent.add_child(mi)
	return mi


func box(parent: Node3D, size: Vector3, c: Color, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	return mesh(parent, b, c, pos, rot)


func cone(parent: Node3D, r: float, h: float, c: Color, pos: Vector3, seg := 6) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = 0.0; m.bottom_radius = r; m.height = h; m.radial_segments = seg; m.rings = 1
	return mesh(parent, m, c, pos)


func cyl(parent: Node3D, r: float, h: float, c: Color, pos: Vector3, seg := 6) -> MeshInstance3D:
	var m := CylinderMesh.new()
	m.top_radius = r; m.bottom_radius = r; m.height = h; m.radial_segments = seg; m.rings = 1
	return mesh(parent, m, c, pos)


func rock(parent: Node3D, r: float, c: Color, pos: Vector3, scl: Vector3) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = r; m.height = r * 2.0; m.radial_segments = 6; m.rings = 3
	return mesh(parent, m, c, pos, Vector3(0, pos.x * 3.1, 0), scl)


func label3d(parent: Node3D, txt: String, pos: Vector3, size := 44) -> Label3D:
	var l := Label3D.new()
	l.text = txt
	l.font_size = size
	l.pixel_size = 0.0085
	l.outline_size = 12
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.position = pos
	parent.add_child(l)
	return l


func flag(parent: Node3D, pos: Vector3, c1: Color, c2: Color, h := 2.6) -> void:
	cyl(parent, 0.04, h, Color(0.45, 0.32, 0.2), pos + Vector3(0, h / 2, 0))
	box(parent, Vector3(0.75, 0.46, 0.03), c1, pos + Vector3(0.4, h - 0.3, 0))
	box(parent, Vector3(0.75, 0.10, 0.035), c2, pos + Vector3(0.4, h - 0.3, 0))


# ---------------------------------------------------------------- dünya
func _build_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.72, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.8, 0.9)
	env.ambient_light_energy = 0.42
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 45.0
	add_child(sun)

	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 18.0
	var center := Vector3(1.0, 0, -2.1)
	var dir := Vector3(0, sin(deg_to_rad(52)), cos(deg_to_rad(52))).rotated(Vector3.UP, deg_to_rad(-18))
	camera.position = center + dir * 30.0
	add_child(camera)
	camera.look_at(center, Vector3.UP)
	camera.current = true

	var ground := PlaneMesh.new(); ground.size = Vector2(70, 70)
	mesh(self, ground, Color(0.46, 0.63, 0.30), Vector3.ZERO)
	# toprak alan (köy merkezi çevresi) + patika
	cyl(self, 3.4, 0.02, Color(0.62, 0.52, 0.36), Vector3(0, 0.01, 0), 9)
	box(self, Vector3(1.2, 0.02, 6.5), Color(0.6, 0.5, 0.35), Vector3(-2.8, 0.012, -2.0), Vector3(0, deg_to_rad(38), 0))
	box(self, Vector3(1.2, 0.02, 5.0), Color(0.6, 0.5, 0.35), Vector3(3.2, 0.012, -1.2), Vector3(0, deg_to_rad(-62), 0))
	# süs: çimen/taş öbekleri (sabit tohum)
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for i in 40:
		var p := Vector3(rng.randf_range(-12, 14), 0, rng.randf_range(-11, 9))
		if p.length() < 4.0:
			continue
		if rng.randf() < 0.75:
			cone(self, 0.18, 0.3, Color(0.36, 0.55, 0.24), p + Vector3(0, 0.15, 0), 4)
		else:
			rock(self, 0.2, Color(0.55, 0.56, 0.55), p, Vector3(1, 0.6, 1))

	_build_town_center()
	_build_forest()
	_build_mine()
	_build_berries()
	_spawn_villagers()


func _add_dropoff(n: Node3D, accepts: Array, radius: float, dname: String) -> void:
	n.set_meta("accepts", accepts)
	n.set_meta("radius", radius)
	n.set_meta("dname", dname)
	dropoffs.append(n)


func _build_town_center() -> void:
	var tc := Node3D.new(); tc.name = "TownCenter"; add_child(tc)
	box(tc, Vector3(3.0, 1.2, 3.0), Color(0.86, 0.78, 0.62), Vector3(0, 0.6, 0))
	box(tc, Vector3(3.2, 0.18, 3.2), Color(0.5, 0.36, 0.22), Vector3(0, 1.25, 0))
	var roof := CylinderMesh.new()
	roof.top_radius = 0.0; roof.bottom_radius = 2.35; roof.height = 1.5; roof.radial_segments = 4; roof.rings = 1
	mesh(tc, roof, Color(0.68, 0.30, 0.20), Vector3(0, 2.08, 0), Vector3(0, PI / 4, 0))
	box(tc, Vector3(0.7, 0.9, 0.06), Color(0.32, 0.22, 0.14), Vector3(0, 0.45, 1.52))
	for x in [-0.95, 0.95]:
		box(tc, Vector3(0.4, 0.35, 0.06), Color(0.25, 0.3, 0.4), Vector3(x, 0.75, 1.52))
	box(tc, Vector3(0.3, 0.8, 0.3), Color(0.55, 0.5, 0.48), Vector3(0.8, 2.3, -0.6))
	flag(tc, Vector3(1.6, 0, 1.6), TUNIC, Color(1, 1, 1), 3.2)
	label3d(tc, "Köy Merkezi", Vector3(0, 3.4, 0), 38)
	_add_dropoff(tc, ["wood", "stone", "food"], 2.0, "Köy Merkezi")


const TREES := [   # x, z, odun
	[5.5, -2.5, 20], [6.9, -3.6, 30], [5.1, -4.7, 30], [7.8, -2.0, 40], [8.3, -4.9, 40],
	[6.5, -6.0, 40], [9.2, -3.2, 50], [7.7, -7.0, 50], [9.7, -5.8, 50], [4.4, -6.5, 40], [9.1, -1.0, 40],
]


func _build_forest() -> void:
	for i in TREES.size():
		var d: Array = TREES[i]
		var r := Node3D.new()
		r.set_script(ResScript)
		r.main = self
		r.kind = "wood"; r.rname = "Ağaç #%d" % (i + 1)
		r.amount = d[2]; r.start_amount = d[2]
		r.stand_r = 0.95; r.pick_r = 0.9; r.pick_h = 1.3
		r.position = Vector3(d[0], 0, d[1])
		add_child(r)
		var vis := Node3D.new(); r.add_child(vis); r.visual = vis
		var s := 0.85 + float(d[2]) / 120.0
		vis.scale = Vector3.ONE * s
		cyl(vis, 0.14, 0.8, Color(0.45, 0.30, 0.18), Vector3(0, 0.4, 0))
		var g := Color(0.20, 0.45 + 0.04 * (i % 3), 0.20)
		cone(vis, 0.8, 1.2, g, Vector3(0, 1.2, 0), 7)
		cone(vis, 0.55, 1.0, g.lightened(0.12), Vector3(0, 1.85, 0), 7)
		r.label = label3d(r, "", Vector3(0, 2.9 * s, 0), 36)
		r._update_label()
		resources.append(r)


func _build_mine() -> void:
	var r := Node3D.new()
	r.set_script(ResScript)
	r.main = self
	r.kind = "stone"; r.rname = "Taş ocağı"
	r.amount = 400; r.start_amount = 400
	r.stand_r = 1.6; r.pick_r = 1.6; r.pick_h = 0.8
	r.position = Vector3(-5.5, 0, -3.5)
	add_child(r)
	var vis := Node3D.new(); r.add_child(vis); r.visual = vis
	var gray := Color(0.58, 0.58, 0.6)
	rock(vis, 1.0, gray, Vector3(0, 0.3, 0), Vector3(1.3, 0.9, 1.1))
	rock(vis, 0.7, gray.darkened(0.12), Vector3(0.9, 0.2, 0.5), Vector3(1, 0.8, 1))
	rock(vis, 0.6, gray.lightened(0.08), Vector3(-0.8, 0.15, 0.6), Vector3(1, 0.7, 1))
	rock(vis, 0.55, gray, Vector3(-0.3, 0.9, -0.3), Vector3(1, 0.8, 1))
	for p in [Vector3(0.3, 0.75, 0.75), Vector3(-0.5, 0.55, 0.9), Vector3(0.9, 0.6, 0.85)]:
		box(vis, Vector3(0.16, 0.12, 0.14), Color(0.95, 0.78, 0.25), p, Vector3(0.3, p.x, 0.2))
	# ahşap giriş çerçevesi
	for x in [-0.4, 0.4]:
		box(vis, Vector3(0.1, 0.9, 0.1), Color(0.48, 0.33, 0.2), Vector3(x, 0.45, 1.05))
	box(vis, Vector3(1.0, 0.12, 0.14), Color(0.48, 0.33, 0.2), Vector3(0, 0.92, 1.05))
	box(vis, Vector3(0.62, 0.78, 0.05), Color(0.15, 0.13, 0.12), Vector3(0, 0.4, 1.0))
	flag(vis, Vector3(1.4, 0, -0.6), Color(0.85, 0.2, 0.18), Color(1.0, 0.85, 0.2), 2.8)
	r.label = label3d(r, "", Vector3(0, 2.4, 0), 38)
	r._update_label()
	resources.append(r)


func _build_berries() -> void:
	var r := Node3D.new()
	r.set_script(ResScript)
	r.main = self
	r.kind = "food"; r.rname = "Çalı"
	r.amount = 150; r.start_amount = 150
	r.stand_r = 1.0; r.pick_r = 1.0; r.pick_h = 0.5
	r.position = Vector3(-5.0, 0, 4.0)
	add_child(r)
	var vis := Node3D.new(); r.add_child(vis); r.visual = vis
	for p in [Vector3(0, 0.3, 0), Vector3(0.45, 0.25, 0.2), Vector3(-0.4, 0.25, 0.25)]:
		rock(vis, 0.4, Color(0.22, 0.5, 0.22), p, Vector3(1, 0.85, 1))
		for k in 3:
			var q: Vector3 = p + Vector3(cos(k * 2.1) * 0.3, 0.2 + 0.05 * k, sin(k * 2.1) * 0.3)
			rock(vis, 0.07, Color(0.85, 0.12, 0.2), q, Vector3.ONE)
	r.label = label3d(r, "", Vector3(0, 1.4, 0), 34)
	r._update_label()
	resources.append(r)


func build_camp(p: Vector3) -> void:
	var c := Node3D.new(); c.name = "LumberCamp"; add_child(c)
	c.position = Vector3(p.x, 0, p.z)
	var wood := Color(0.52, 0.36, 0.22)
	for q in [Vector3(-0.6, 0, -0.5), Vector3(0.6, 0, -0.5), Vector3(-0.6, 0, 0.5), Vector3(0.6, 0, 0.5)]:
		box(c, Vector3(0.12, 1.1, 0.12), wood, q + Vector3(0, 0.55, 0))
	box(c, Vector3(1.6, 0.1, 1.4), Color(0.62, 0.42, 0.25), Vector3(0, 1.15, 0), Vector3(0.25, 0, 0))
	for i in 4:
		cyl(c, 0.1, 1.0, Color(0.6, 0.42, 0.24), Vector3(-0.25 + 0.17 * (i % 3), 0.12 + 0.18 * (i / 3), 0.0), 6).rotation = Vector3(0, 0, PI / 2)
	label3d(c, "Kereste kampı", Vector3(0, 1.9, 0), 34)
	_add_dropoff(c, ["wood"], 1.0, "Kereste kampı")
	print("[insa] %.2f sn: kereste kampı kuruldu (%.1f, %.1f) — odun en yakın teslim yerine götürülür" % [t, c.position.x, c.position.z])


func _spawn_villagers() -> void:
	var spots := [Vector3(-1.2, 0, 3.0), Vector3(0.0, 0, 3.0), Vector3(1.2, 0, 3.0),
		Vector3(-1.4, 0, 5.0), Vector3(-0.2, 0, 5.0), Vector3(1.8, 0, 5.0)]
	for i in spots.size():
		var v := Node3D.new()
		v.set_script(VillagerScript)
		v.main = self
		v.vid = i + 1
		v.position = spots[i]
		add_child(v)
		v.build(TUNIC)
		villagers.append(v)


func _count_kind(k: String) -> int:
	var n := 0
	for r in resources:
		if r.kind == k and not r.depleted:
			n += 1
	return n


func _sum_kind(k: String) -> int:
	var n := 0
	for r in resources:
		if r.kind == k and not r.depleted:
			n += r.amount
	return n


# ---------------------------------------------------------------- oyun sorguları
func nearest_resource(kind: String, from: Vector3, maxd: float) -> Node3D:
	var best: Node3D = null
	var bd := maxd
	for r in resources:
		if r.kind != kind or r.depleted:
			continue
		var d: float = from.distance_to(r.position)
		if d < bd:
			bd = d; best = r
	return best


func nearest_dropoff(kind: String, from: Vector3) -> Node3D:
	var best: Node3D = null
	var bd := INF
	for d in dropoffs:
		if not (kind in d.get_meta("accepts")):
			continue
		var dist: float = from.distance_to(d.position) - float(d.get_meta("radius"))
		if dist < bd:
			bd = dist; best = d
	return best


func separation(v: Node3D) -> Vector3:
	var f := Vector3.ZERO
	for o in villagers:
		if o == v:
			continue
		var d: Vector3 = v.position - o.position
		d.y = 0.0
		var l := d.length()
		if l < 0.75 and l > 0.001:
			f += d / l * (0.75 - l) * 5.0
	return f


func add_stock(k: String, n: int) -> void:
	stock[k] += n


func on_resource_depleted(r: Node3D) -> void:
	print("[kaynak] %.2f sn: %s bitti (%d %s çıktı) — sahneden kalkıyor" % [t, r.rname, r.start_amount, KIND_TR[r.kind]])
	if r.label:
		r.label.visible = false
	if r.kind == "wood":
		var stump := cyl(r, 0.17, 0.25, Color(0.45, 0.30, 0.18), Vector3(0, 0.12, 0))
		stump.scale = r.visual.scale
		var tw := create_tween()
		var side := Vector3(deg_to_rad(80), 0, deg_to_rad(25))
		tw.tween_property(r.visual, "rotation", side, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.tween_property(r.visual, "scale", Vector3.ONE * 0.01, 0.5)
		tw.tween_callback(r.visual.queue_free)
	else:
		r.visual.visible = false


func float_text(p: Vector3, txt: String, c: Color) -> void:
	var l := label3d(self, txt, p, 46)
	l.modulate = c
	var tw := create_tween()
	tw.tween_property(l, "position", p + Vector3(0, 1.4, 0), 1.3)
	tw.parallel().tween_property(l, "modulate:a", 0.0, 1.3).set_delay(0.5)
	tw.tween_callback(l.queue_free)


func set_caption(s: String) -> void:
	caption = s
	caption_t = t
	print("[yazi] %.2f sn: %s" % [t, s])


# ---------------------------------------------------------------- girdi (oyuncunun yolu)
func _input(event: InputEvent) -> void:
	# Kayıt modunda yalnız sürücünün olayları geçer: 1. pencereli kayıtta gönderilmemiş bir sol tık
	# "Boşta köylü" düğmesine bastı (dış girdi sızması). Yutulan her olay sayılır ve yazılır.
	if auto_mode and (event is InputEventMouse or event is InputEventKey) and event.device != DRIVER_DEVICE:
		foreign_blocked += 1
		if event is InputEventMouseButton or event is InputEventKey or foreign_blocked <= 3:
			print("[dis-girdi] %.2f sn: sürücüye ait olmayan olay yutuldu #%d: %s" % [t, foreign_blocked, event.as_text()])
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouse:
		mouse_events_in += 1
		cursor_pos = event.position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag = true; _drag_a = mb.position; _drag_b = mb.position
			elif _drag:
				_drag = false
				_drag_b = mb.position
				_finish_select()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_command(mb.position)
	elif event is InputEventMouseMotion and _drag:
		_drag_b = (event as InputEventMouseMotion).position
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if k == KEY_PERIOD:
			select_next_idle()
		elif k == KEY_K:
			var g = _ground_at(cursor_pos)
			if g != null:
				build_camp(g)


func _screen(p: Vector3) -> Vector2:
	return camera.unproject_position(p)


func _ground_at(sp: Vector2):
	var o := camera.project_ray_origin(sp)
	var n := camera.project_ray_normal(sp)
	if absf(n.y) < 1e-4:
		return null
	var k := -o.y / n.y
	return o + n * k


func _set_selection(arr: Array) -> void:
	for v in selection:
		v.set_selected(false)
	selection = arr
	for v in selection:
		v.set_selected(true)


func _finish_select() -> void:
	var rect := Rect2(_drag_a, _drag_b - _drag_a).abs()
	var picked: Array = []
	var how := ""
	if rect.size.length() < 8.0:
		how = "tık (%.0f, %.0f)" % [_drag_b.x, _drag_b.y]
		var best: Node3D = null
		var bd := 40.0
		for v in villagers:
			var d := _screen(v.position + Vector3(0, 0.7, 0)).distance_to(_drag_b)
			if d < bd:
				bd = d; best = v
		if best:
			picked = [best]
	else:
		how = "kutu (%.0f, %.0f)-(%.0f, %.0f)" % [rect.position.x, rect.position.y, rect.end.x, rect.end.y]
		for v in villagers:
			if rect.has_point(_screen(v.position + Vector3(0, 0.7, 0))):
				picked.append(v)
	_set_selection(picked)
	print("[secim] %.2f sn: %s → %d köylü %s" % [t, how, picked.size(), _ids(picked)])


func _ids(arr: Array) -> String:
	var s: PackedStringArray = []
	for v in arr:
		s.append("#%d" % v.vid)
	return "[" + ", ".join(s) + "]"


func pick_resource(sp: Vector2) -> Node3D:
	var g = _ground_at(sp)
	var best: Node3D = null
	var bd := 60.0
	for r in resources:
		if r.depleted:
			continue
		var ds := _screen(r.position + Vector3(0, r.pick_h, 0)).distance_to(sp)
		var on_ground: bool = g != null and Vector2(g.x - r.position.x, g.z - r.position.z).length() < r.pick_r
		if on_ground:
			ds = minf(ds, 1.0)
		if ds < bd:
			bd = ds; best = r
	return best


func _command(sp: Vector2) -> void:
	pings.append([sp, t])
	if selection.is_empty():
		print("[komut] %.2f sn: sağ tık (%.0f, %.0f) ama seçili köylü yok" % [t, sp.x, sp.y])
		return
	var r := pick_resource(sp)
	if r:
		var n := selection.size()
		for i in n:
			selection[i].assign(r, (i - (n - 1) / 2.0) * 1.15)
		print("[komut] %.2f sn: sağ tık (%.0f, %.0f) → %s (%d %s kaldı) · %d köylü %s"
			% [t, sp.x, sp.y, r.rname, r.amount, KIND_TR[r.kind], n, _ids(selection)])
	else:
		var g = _ground_at(sp)
		if g == null:
			return
		for i in selection.size():
			selection[i].move_to(g + Vector3((i % 3) * 0.7 - 0.7, 0, (i / 3) * 0.7))
		print("[komut] %.2f sn: sağ tık zemine (%.1f, %.1f) → yürü" % [t, g.x, g.z])


func idle_villagers() -> Array:
	var a: Array = []
	for v in villagers:
		if v.is_idle():
			a.append(v)
	return a


func select_next_idle() -> void:
	var idle := idle_villagers()
	if idle.is_empty():
		print("[secim] %.2f sn: boşta köylü düğmesi — boşta köylü yok" % t)
		return
	var v: Node3D = idle[_idle_cycle % idle.size()]
	_idle_cycle += 1
	_set_selection([v])
	print("[secim] %.2f sn: boşta köylü düğmesi → #%d seçildi (%d boşta)" % [t, v.vid, idle.size()])


# ---------------------------------------------------------------- döngü
func _physics_process(delta: float) -> void:
	t += delta
	for v in villagers:
		v.step(delta)
	if t + 1e-6 >= _next_log:
		_next_log += log_every
		print("[sayac] %.2f sn: odun %d · taş %d · yiyecek %d · boşta %d · ormanda kalan odun %d (%d ağaç)"
			% [t, stock.wood, stock.stone, stock.food, idle_villagers().size(), _sum_kind("wood"), _count_kind("wood")])
	if not _summary_done and t >= summary_at:
		_summary_done = true
		_print_summary()


func _process(_d: float) -> void:
	for k in lbl_res:
		lbl_res[k].text = "%s  %d" % [KIND_TR[k].capitalize(), stock[k]]
	lbl_time.text = "t = %.1f sn" % t
	var idle := idle_villagers().size()
	btn_idle.text = "Boşta köylü: %d" % idle
	btn_idle.modulate = Color(1, 0.9, 0.3) if idle > 0 else Color(0.7, 0.75, 0.8)
	if selection.is_empty():
		lbl_sel.text = "Seçili yok  ·  sol tık/sürükle: seç  ·  sağ tık kaynağa: gönder"
	else:
		var jobs := {}
		for v in selection:
			jobs[v.job_name()] = jobs.get(v.job_name(), 0) + 1
		var parts: PackedStringArray = []
		for j in jobs:
			parts.append("%d %s" % [jobs[j], j])
		lbl_sel.text = "Seçili: %d köylü (%s)" % [selection.size(), ", ".join(parts)]
	lbl_cap.text = caption
	lbl_cap.modulate.a = clampf(1.0 - (t - caption_t - 2.6) / 0.5, 0.0, 1.0) if caption != "" else 0.0
	overlay.queue_redraw()


func _print_summary() -> void:
	var wall := (Time.get_ticks_usec() - _wall0) / 1e6
	print("[ozet] %.2f sn (duvar saati %.2f sn): odun %d · taş %d · yiyecek %d · boşta %d · fare olayı alındı %d, dış olay yutuldu %d"
		% [t, wall, stock.wood, stock.stone, stock.food, idle_villagers().size(), mouse_events_in, foreign_blocked])
	var per_kind := {}
	for v in villagers:
		var work: float = t - v.first_cmd_t if v.first_cmd_t >= 0.0 else 0.0
		var tot: int = v.deposited.wood + v.deposited.stone + v.deposited.food
		var spd: float = v.move_dist / v.move_time if v.move_time > 0.0 else 0.0
		var line := "[ozet] köylü #%d %s: teslim %d, toplam %d (odun %d, taş %d), yürüme hızı ölçülen %.3f m/sn (%.1f m / %.2f sn)" % [
			v.vid, v.job_name(), v.trips.size(), tot, v.deposited.wood, v.deposited.stone, spd, v.move_dist, v.move_time]
		if work > 0.0 and tot > 0:
			line += ", komuttan beri %.1f sn → %.1f birim/dk" % [work, tot / work * 60.0]
		print(line)
		if v.job_kind != "" and v.trips.size() >= 2:
			if not per_kind.has(v.job_kind):
				per_kind[v.job_kind] = []
			for i in range(1, v.trips.size()):   # ilk tur başlangıç yürüyüşünü içerir → kararlı turlar
				per_kind[v.job_kind].append(v.trips[i])
	for k in per_kind:
		var a: Array = per_kind[k]
		var s := [0.0, 0.0, 0.0, 0.0]
		var amt := 0
		for tr in a:
			for j in 4:
				s[j] += tr[j]
			amt += tr[5]
		var n := float(a.size())
		print("[ozet] %s kararlı tur (ilk tur hariç, %d tur): ort %.2f sn = yürüme %.2f + toplama %.2f + dönüş %.2f · tur başına %.1f birim → %.1f %s/dk/köylü"
			% [k, a.size(), s[0] / n, s[1] / n, s[2] / n, s[3] / n, amt / n, (amt / n) / (s[0] / n) * 60.0, KIND_TR[k]])
	print("[ozet] kalan: ağaç %d (odun %d), taş ocağı %d" % [_count_kind("wood"), _sum_kind("wood"), _sum_kind("stone")])


# ---------------------------------------------------------------- arayüz
class Overlay extends Control:
	var m: Node
	func _draw() -> void:
		if m._drag:
			var r := Rect2(m._drag_a, m._drag_b - m._drag_a).abs()
			draw_rect(r, Color(0.4, 1.0, 0.45, 0.15), true)
			draw_rect(r, Color(0.4, 1.0, 0.45, 0.95), false, 2.5)
		for p in m.pings:
			var age: float = m.t - p[1]
			if age < 0.6:
				var k := age / 0.6
				draw_arc(p[0], 10.0 + 30.0 * k, 0, TAU, 32, Color(0.3, 1.0, 0.3, 1.0 - k), 4.0)
		var c: Vector2 = m.cursor_pos
		var pts := PackedVector2Array([c, c + Vector2(0, 30), c + Vector2(8, 23), c + Vector2(14, 36),
			c + Vector2(19, 34), c + Vector2(13, 21), c + Vector2(23, 21)])
		draw_colored_polygon(pts, Color(1, 1, 1))
		pts.append(c)
		draw_polyline(pts, Color(0, 0, 0), 2.0)


func _panel(parent: Control, rect: Rect2) -> Panel:
	var p := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.78)
	sb.set_corner_radius_all(10)
	p.add_theme_stylebox_override("panel", sb)
	p.position = rect.position; p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(p)
	return p


func _label(parent: Control, txt: String, pos: Vector2, size: int, c := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = txt
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 6)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _build_hud() -> void:
	var cl := CanvasLayer.new(); add_child(cl)
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cl.add_child(hud)
	_panel(hud, Rect2(16, 14, 1048, 66))
	var x := 34.0
	for k in ["wood", "stone", "food"]:
		var sw := ColorRect.new()
		sw.color = KIND_COL[k]; sw.position = Vector2(x, 33); sw.size = Vector2(28, 28)
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud.add_child(sw)
		lbl_res[k] = _label(hud, "", Vector2(x + 38, 24), 34)
		x += 250.0
	lbl_time = _label(hud, "", Vector2(870, 26), 30, Color(0.8, 0.85, 0.9))
	btn_idle = Button.new()
	btn_idle.text = "Boşta köylü: 0"
	btn_idle.position = Vector2(16, 92); btn_idle.size = Vector2(250, 52)
	btn_idle.focus_mode = Control.FOCUS_NONE
	btn_idle.add_theme_font_size_override("font_size", 28)
	btn_idle.pressed.connect(select_next_idle)
	hud.add_child(btn_idle)
	lbl_cap = _label(hud, "", Vector2(286, 98), 30, Color(1, 0.95, 0.6))
	_panel(hud, Rect2(16, 1004, 1048, 60))
	lbl_sel = _label(hud, "", Vector2(34, 1013), 28)
	overlay = Overlay.new()
	overlay.m = self
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(overlay)
