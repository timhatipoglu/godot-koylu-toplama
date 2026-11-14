extends Node
## YALNIZ kayıt/test için: oyuncunun yapacağını GERÇEK fare/tuş olaylarıyla yapar (Input.parse_input_event).
## Komut satırında `-- --auto-rts` yoksa hiçbir şey yapmaz. main.gd bundan habersizdir: seçim kutusu,
## sağ tık ve "Boşta köylü" düğmesi oyuncu tıklamasıyla aynı _unhandled_input / GUI yolundan geçer.
## Hedef ekran noktaları oyuncunun gördüğü yerden hesaplanır (camera.unproject_position).
## `--camp`: önce imleci orman kenarına götürüp K'ye basar (kereste kampı kur).

var m: Node
var _pos := Vector2(540, 760)
var _mask := 0
var sent := 0


func _ready() -> void:
	if not ("--auto-rts" in OS.get_cmdline_user_args()):
		return
	m = get_parent()
	_run.call_deferred()


func _run() -> void:
	var camp := "--camp" in OS.get_cmdline_user_args()
	await _at(0.1)
	_motion(_pos)
	if camp:
		await _move_to(m._screen(m.CAMP_POS), 0.25)
		_key(KEY_K)
		m.set_caption("K: orman kenarına kereste kampı")
	# 1) 3 köylüyü kutuyla seç → ağaca sağ tık
	var a := _rect_of([m.villagers[0], m.villagers[1], m.villagers[2]])
	await _move_to(a.position, 0.35)
	_button(MOUSE_BUTTON_LEFT, true)
	await _move_to(a.end, 0.35)
	_button(MOUSE_BUTTON_LEFT, false)
	m.set_caption("3 köylü seçildi")
	await _move_to(m._screen(m.resources[0].position + Vector3(0, 1.3, 0)), 0.4)
	await _at(m.t + 0.12)
	_button(MOUSE_BUTTON_RIGHT, true); _button(MOUSE_BUTTON_RIGHT, false)
	m.set_caption("Sağ tık ağaca → 3 ODUNCU")
	# 2) 2 köylüyü seç → taş ocağına sağ tık
	await _at(m.t + 0.08)
	var b := _rect_of([m.villagers[3], m.villagers[4]])
	await _move_to(b.position, 0.35)
	_button(MOUSE_BUTTON_LEFT, true)
	await _move_to(b.end, 0.3)
	_button(MOUSE_BUTTON_LEFT, false)
	m.set_caption("2 köylü seçildi")
	await _move_to(m._screen(m.resources[11].position + Vector3(0, 0.8, 0)), 0.4)
	await _at(m.t + 0.12)
	_button(MOUSE_BUTTON_RIGHT, true); _button(MOUSE_BUTTON_RIGHT, false)
	m.set_caption("Sağ tık taş ocağına → 2 TAŞÇI")
	# 3) boşta köylü düğmesi → taş ocağı
	await _at(m.t + 0.15)
	var br: Rect2 = m.btn_idle.get_global_rect()
	await _move_to(br.get_center(), 0.45)
	await _at(m.t + 0.1)
	_button(MOUSE_BUTTON_LEFT, true)
	await _at(m.t + 0.08)
	_button(MOUSE_BUTTON_LEFT, false)
	m.set_caption("Boşta köylü düğmesi → 1 köylü")
	await _move_to(m._screen(m.resources[11].position + Vector3(0.3, 0.8, 0.3)), 0.5)
	await _at(m.t + 0.12)
	_button(MOUSE_BUTTON_RIGHT, true); _button(MOUSE_BUTTON_RIGHT, false)
	m.set_caption("Boştaki köylü de taş ocağına")
	await _at(m.t + 0.3)
	await _move_to(Vector2(930, 860), 0.6)
	print("[auto-rts] %.2f sn: sürücü bitti, %d olay gönderildi" % [m.t, sent])


func _rect_of(vs: Array) -> Rect2:
	var r := Rect2(m._screen(vs[0].position + Vector3(0, 0.7, 0)), Vector2.ZERO)
	for v in vs:
		r = r.expand(m._screen(v.position + Vector3(0, 0.7, 0)))
	return r.grow(38.0)


func _at(tt: float) -> void:
	while m.t < tt - 1e-6:
		await get_tree().physics_frame


func _move_to(p: Vector2, dur: float) -> void:
	var p0 := _pos
	var t0: float = m.t
	while true:
		await get_tree().physics_frame
		var k := clampf((m.t - t0) / dur, 0.0, 1.0)
		_motion(p0.lerp(p, smoothstep(0.0, 1.0, k)))
		if k >= 1.0:
			break


## Hedefler viewport (1080×1080) koordinatında hesaplanır; olay PENCERE koordinatında gönderilir
## (stretch=viewport: pencere ekrana sığmayınca küçülür, Godot olayı geri viewport'a çevirir).
func _send(ev: InputEventMouse) -> void:
	var xf: Transform2D = get_viewport().get_final_transform()
	ev.position = xf * ev.position
	ev.global_position = ev.position
	if ev is InputEventMouseMotion:
		ev.relative = xf.basis_xform(ev.relative)
	ev.device = m.DRIVER_DEVICE
	Input.parse_input_event(ev)


func _motion(p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = p
	ev.global_position = p
	ev.relative = p - _pos
	ev.button_mask = _mask
	_pos = p
	_send(ev)
	sent += 1


func _button(b: MouseButton, pressed: bool) -> void:
	var bit := 1 << (b - 1)
	_mask = (_mask | bit) if pressed else (_mask & ~bit)
	var ev := InputEventMouseButton.new()
	ev.button_index = b
	ev.pressed = pressed
	ev.position = _pos
	ev.global_position = _pos
	ev.button_mask = _mask
	_send(ev)
	sent += 1
	print("[auto-rts] %.2f sn: %s %s (%.0f, %.0f)" % [m.t, "sol" if b == MOUSE_BUTTON_LEFT else "sağ",
		"bas" if pressed else "bırak", _pos.x, _pos.y])


func _key(k: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = k
		ev.physical_keycode = k
		ev.pressed = pressed
		ev.device = m.DRIVER_DEVICE
		Input.parse_input_event(ev)
		sent += 1
	print("[auto-rts] %.2f sn: %s tuşu" % [m.t, OS.get_keycode_string(k)])
