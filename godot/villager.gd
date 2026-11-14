extends Node3D
## Köylü: IDLE → TO_RES (yürü) → GATHER (topla, taşıma kapasitesi CAP) → TO_DROP (en yakın teslim yeri)
## → teslim → aynı kaynağa geri döner. Kaynak biterse yakındaki aynı tür kaynağa geçer; hiç yoksa boşta kalır.
## Rol (oduncu/taşçı/toplayıcı) kaynağa sağ tık ile atanır; şapka + alet değişir.

const SPEED := 3.5                       # m/sn (video için hızlandırılmış değer)
const CAP := 10                          # taşıma kapasitesi
const RATES := {"wood": 5.0, "stone": 4.0, "food": 4.0}   # birim/sn toplama hızı
const JOBS := {"": "köylü", "wood": "oduncu", "stone": "taşçı", "food": "toplayıcı"}
const KIND_TR := {"wood": "odun", "stone": "taş", "food": "yiyecek"}
enum S {IDLE, MOVE, TO_RES, GATHER, TO_DROP}

var main: Node
var vid := 0
var state := S.IDLE
var job_kind := ""
var res: Node3D = null
var drop: Node3D = null
var carry := 0
var carry_kind := ""
var target := Vector3.ZERO
var slot_ang := 0.0
var selected := false
var _acc := 0.0
var _phase := 0.0
var _gt := 0.0
var _was_idle_logged := true

# ölçüm
var trip_start := -1.0
var seg_start := -1.0
var t_out := 0.0
var t_gather := 0.0
var t_back := 0.0
var trips: Array = []            # [süre, yürüme, toplama, dönüş, teslim yeri]
var deposited := {"wood": 0, "stone": 0, "food": 0}
var first_cmd_t := -1.0
var move_dist := 0.0
var move_time := 0.0

# görsel parçalar
var leg_l: Node3D
var leg_r: Node3D
var arm_l: Node3D
var arm_r: Node3D
var hat: MeshInstance3D
var tool_axe: Node3D
var tool_pick: Node3D
var tool_basket: Node3D
var load_wood: Node3D
var load_stone: Node3D
var load_food: Node3D
var ring: MeshInstance3D
var body_root: Node3D


func build(tunic: Color) -> void:
	body_root = Node3D.new()
	body_root.scale = Vector3.ONE * 1.25
	add_child(body_root)
	var pants := Color(0.36, 0.25, 0.16)
	var skin := Color(0.93, 0.74, 0.58)
	leg_l = _pivot(Vector3(-0.09, 0.42, 0))
	leg_r = _pivot(Vector3(0.09, 0.42, 0))
	for lg in [leg_l, leg_r]:
		main.box(lg, Vector3(0.12, 0.42, 0.13), pants, Vector3(0, -0.21, 0))
	var torso := CylinderMesh.new()
	torso.top_radius = 0.15; torso.bottom_radius = 0.22; torso.height = 0.46
	torso.radial_segments = 6; torso.rings = 1
	main.mesh(body_root, torso, tunic, Vector3(0, 0.64, 0))
	main.box(body_root, Vector3(0.40, 0.05, 0.40), Color(0.30, 0.20, 0.12), Vector3(0, 0.47, 0))  # kemer
	var head := SphereMesh.new()
	head.radius = 0.14; head.height = 0.28; head.radial_segments = 7; head.rings = 4
	main.mesh(body_root, head, skin, Vector3(0, 1.0, 0))
	var hm := CylinderMesh.new()
	hm.top_radius = 0.0; hm.bottom_radius = 0.22; hm.height = 0.16; hm.radial_segments = 7; hm.rings = 1
	hat = main.mesh(body_root, hm, Color(0.86, 0.76, 0.42), Vector3(0, 1.15, 0))
	arm_l = _pivot(Vector3(-0.21, 0.83, 0))
	arm_r = _pivot(Vector3(0.21, 0.83, 0))
	for a in [arm_l, arm_r]:
		main.box(a, Vector3(0.08, 0.36, 0.08), tunic.darkened(0.15), Vector3(0, -0.18, 0))
		main.box(a, Vector3(0.08, 0.08, 0.08), skin, Vector3(0, -0.38, 0))
	# aletler sağ elde (el: kol pivotunun -0.38 altında); sap ileri (+Z) uzanır
	tool_axe = Node3D.new(); arm_r.add_child(tool_axe); tool_axe.position = Vector3(0, -0.38, 0)
	main.box(tool_axe, Vector3(0.04, 0.04, 0.55), Color(0.55, 0.38, 0.2), Vector3(0, 0, 0.2))
	main.box(tool_axe, Vector3(0.03, 0.18, 0.12), Color(0.75, 0.77, 0.8), Vector3(0, 0.07, 0.44))
	tool_pick = Node3D.new(); arm_r.add_child(tool_pick); tool_pick.position = Vector3(0, -0.38, 0)
	main.box(tool_pick, Vector3(0.04, 0.04, 0.55), Color(0.55, 0.38, 0.2), Vector3(0, 0, 0.2))
	main.box(tool_pick, Vector3(0.04, 0.34, 0.05), Color(0.5, 0.52, 0.56), Vector3(0, 0.0, 0.46))
	tool_basket = Node3D.new(); arm_l.add_child(tool_basket); tool_basket.position = Vector3(0, -0.42, 0.06)
	main.box(tool_basket, Vector3(0.2, 0.14, 0.16), Color(0.7, 0.55, 0.3), Vector3.ZERO)
	# taşınan yük (sırtta / omuzda)
	load_wood = Node3D.new(); body_root.add_child(load_wood); load_wood.position = Vector3(0, 0.82, -0.2)
	for i in 3:
		var lm := CylinderMesh.new()
		lm.top_radius = 0.06; lm.bottom_radius = 0.06; lm.height = 0.5; lm.radial_segments = 6; lm.rings = 1
		main.mesh(load_wood, lm, Color(0.58, 0.40, 0.22), Vector3(-0.07 + 0.07 * i, 0.06 * (i % 2), 0), Vector3(0, 0, PI / 2))
	load_stone = Node3D.new(); body_root.add_child(load_stone); load_stone.position = Vector3(0, 0.85, -0.2)
	var sm := SphereMesh.new()
	sm.radius = 0.16; sm.height = 0.26; sm.radial_segments = 5; sm.rings = 3
	main.mesh(load_stone, sm, Color(0.62, 0.62, 0.64), Vector3.ZERO)
	load_food = Node3D.new(); body_root.add_child(load_food); load_food.position = Vector3(0, 0.85, -0.2)
	main.box(load_food, Vector3(0.24, 0.16, 0.2), Color(0.7, 0.55, 0.3), Vector3.ZERO)
	main.box(load_food, Vector3(0.18, 0.06, 0.14), Color(0.8, 0.15, 0.2), Vector3(0, 0.1, 0))
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42; tm.outer_radius = 0.5; tm.rings = 24; tm.ring_segments = 4
	ring = MeshInstance3D.new(); ring.mesh = tm
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.albedo_color = Color(0.3, 1.0, 0.35)
	ring.material_override = rm
	ring.position = Vector3(0, 0.03, 0); ring.scale = Vector3(1, 0.3, 1)
	add_child(ring)
	_apply_job_visual()
	_apply_load_visual()
	set_selected(false)


func _pivot(p: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = p
	body_root.add_child(n)
	return n


func set_selected(on: bool) -> void:
	selected = on
	ring.visible = on


func is_idle() -> bool:
	return state == S.IDLE


func job_name() -> String:
	return JOBS[job_kind]


# --- komutlar -------------------------------------------------------------
func assign(r: Node3D, ang: float) -> void:
	slot_ang = ang
	if first_cmd_t < 0.0:
		first_cmd_t = main.t
	if job_kind != r.kind:
		var old: String = JOBS[job_kind]
		job_kind = r.kind
		print("[koylu %d] %.2f sn: rol %s → %s (%s)" % [vid, main.t, old, JOBS[job_kind], r.rname])
		_apply_job_visual()
		main.float_text(position + Vector3(0, 2.0, 0), JOBS[job_kind].to_upper() + "!", Color(1, 0.95, 0.5))
	if carry > 0 and carry_kind != r.kind:
		carry = 0       # farklı kaynağa geçince eldeki yük düşer (klasik RTS davranışı)
		_apply_load_visual()
	trip_start = main.t
	t_out = 0.0; t_gather = 0.0; t_back = 0.0
	_go_res(r)


func move_to(p: Vector3) -> void:
	res = null
	target = p
	state = S.MOVE
	trip_start = -1.0


func _go_res(r: Node3D) -> void:
	res = r
	var away := position - r.position
	away.y = 0.0
	if away.length() < 0.01:
		away = Vector3(0, 0, 1)
	away = away.normalized().rotated(Vector3.UP, slot_ang)
	target = r.position + away * r.stand_r
	state = S.TO_RES
	seg_start = main.t
	_was_idle_logged = false


func _go_drop() -> void:
	drop = main.nearest_dropoff(carry_kind, position)
	if drop == null:
		_set_idle("teslim yeri yok")
		return
	var away := position - drop.position
	away.y = 0.0
	away = away.normalized()
	target = drop.position + away * float(drop.get_meta("radius"))
	t_gather += main.t - seg_start
	seg_start = main.t
	state = S.TO_DROP


func _set_idle(why: String) -> void:
	state = S.IDLE
	res = null
	if not _was_idle_logged:
		print("[koylu %d] %.2f sn: BOŞTA (%s)" % [vid, main.t, why])
		_was_idle_logged = true


func _next_resource() -> Node3D:
	var from: Vector3 = res.position if res != null else position
	return main.nearest_resource(job_kind, from, 14.0)


# --- adım ------------------------------------------------------------------
func step(delta: float) -> void:
	_gt += delta
	var moving := false
	match state:
		S.IDLE:
			pass
		S.MOVE:
			moving = true
			if _walk(delta):
				_set_idle("hedefe vardı")
		S.TO_RES:
			moving = true
			if res == null or res.depleted:
				var nx := _next_resource()
				if nx and carry < CAP:
					_go_res(nx)
				elif carry > 0:
					t_out += main.t - seg_start; seg_start = main.t
					_go_drop()
				else:
					_set_idle("kaynak bitti")
			elif _walk(delta):
				t_out += main.t - seg_start
				seg_start = main.t
				carry_kind = res.kind
				state = S.GATHER
		S.GATHER:
			_face((res.position - position) if res else Vector3.FORWARD)
			if res == null or res.depleted:
				var nx2 := _next_resource()
				if nx2 and carry < CAP:
					t_gather += main.t - seg_start
					_go_res(nx2)
				elif carry > 0:
					_go_drop()
				else:
					_set_idle("kaynak bitti")
			else:
				_acc += float(RATES[res.kind]) * delta
				while _acc >= 1.0 and carry < CAP and not res.depleted:
					_acc -= 1.0
					carry += res.take(1)
				_apply_load_visual()
				if carry >= CAP:
					_acc = 0.0
					_go_drop()
		S.TO_DROP:
			moving = true
			if _walk(delta):
				_deposit()
	_animate(delta, moving)


func _deposit() -> void:
	t_back += main.t - seg_start
	var n := carry
	var k := carry_kind
	main.add_stock(k, n)
	deposited[k] += n
	carry = 0
	_apply_load_visual()
	var dur: float = main.t - trip_start
	var dname: String = drop.get_meta("dname")
	trips.append([dur, t_out, t_gather, t_back, dname, n])
	print("[koylu %d] %.2f sn: %d %s bıraktı (%s) · tur %.2f sn = yürüme %.2f + toplama %.2f + dönüş %.2f · teslim #%d"
		% [vid, main.t, n, KIND_TR[k], dname, dur, t_out, t_gather, t_back, trips.size()])
	main.float_text(drop.position + Vector3((vid - 3.5) * 0.45, 3.9 + 0.25 * (vid % 3), 0), "+%d %s" % [n, KIND_TR[k]], main.KIND_COL[k])
	trip_start = main.t
	t_out = 0.0; t_gather = 0.0; t_back = 0.0
	var r := res
	if r == null or r.depleted:
		r = _next_resource()
	if r:
		_go_res(r)
	else:
		_set_idle("yakında %s kalmadı" % KIND_TR[k])


func _walk(delta: float) -> bool:
	var to := target - position
	to.y = 0.0
	var d := to.length()
	if d < 0.06:
		return true
	var dir := to / d
	var v := dir * SPEED
	if d > 0.6:
		v += main.separation(self)
		v = v.limit_length(SPEED)
	var stp := v * delta
	if stp.length() >= d:
		stp = to
	position += stp
	move_dist += stp.length()
	move_time += delta
	_face(v)
	return false


func _face(v: Vector3) -> void:
	v.y = 0.0
	if v.length() < 0.01:
		return
	var want := atan2(v.x, v.z)
	rotation.y = rotate_toward(rotation.y, want, 12.0 * get_physics_process_delta_time())


func _animate(delta: float, moving: bool) -> void:
	if moving:
		_phase += delta * 11.0
		var s := sin(_phase)
		leg_l.rotation.x = s * 0.6
		leg_r.rotation.x = -s * 0.6
		arm_l.rotation.x = -s * 0.5
		arm_r.rotation.x = s * 0.5 - (0.5 if job_kind != "" else 0.0)
		body_root.position.y = abs(cos(_phase)) * 0.05
	else:
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.0, 0.2)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.0, 0.2)
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.0, 0.2)
		body_root.position.y = 0.0
		if state == S.GATHER:
			# vuruş: kol yukarıdan aşağı (topla hızına bağlı ritim)
			var c := fmod(_gt * 2.2, 1.0)
			arm_r.rotation.x = lerpf(-2.4, -0.5, smoothstep(0.0, 0.35, c)) if c < 0.35 else lerpf(-0.5, -2.4, (c - 0.35) / 0.65)
			body_root.rotation.x = 0.12 if c < 0.35 else 0.0
		else:
			arm_r.rotation.x = lerpf(arm_r.rotation.x, 0.0, 0.2)
			body_root.rotation.x = 0.0


func _apply_job_visual() -> void:
	tool_axe.visible = job_kind == "wood"
	tool_pick.visible = job_kind == "stone"
	tool_basket.visible = job_kind == "food"
	var c := Color(0.86, 0.76, 0.42)
	if job_kind == "wood": c = Color(0.20, 0.55, 0.22)
	elif job_kind == "stone": c = Color(0.45, 0.47, 0.52)
	elif job_kind == "food": c = Color(0.85, 0.35, 0.35)
	hat.material_override = main.flat_mat(c)


func _apply_load_visual() -> void:
	var k := clampf(float(carry) / CAP, 0.0, 1.0)
	for pair in [[load_wood, "wood"], [load_stone, "stone"], [load_food, "food"]]:
		var nd: Node3D = pair[0]
		nd.visible = carry > 0 and carry_kind == pair[1]
		nd.scale = Vector3.ONE * (0.45 + 0.55 * k)
