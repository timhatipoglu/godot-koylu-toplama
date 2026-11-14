extends Node3D
## Toplanabilir kaynak: ağaç (odun), taş ocağı (taş), çalı (yiyecek).
## Miktar biter → `depleted` olur, sahneden düşer (ağaç devrilir, kütük kalır).

var main: Node
var kind := "wood"          # wood / stone / food
var rname := "Ağaç"
var amount := 20
var start_amount := 20
var stand_r := 0.8          # köylünün kaynağın merkezine uzaklığı (toplarken)
var pick_r := 0.9           # yer düzleminde tıklama yarıçapı
var pick_h := 1.2           # ekranda tıklama noktasının yerden yüksekliği
var depleted := false
var label: Label3D
var visual: Node3D
var _shake := 0.0
var _t := 0.0


func take(n: int) -> int:
	if depleted:
		return 0
	var got: int = mini(n, amount)
	amount -= got
	_shake = 0.18
	_update_label()
	if amount <= 0:
		depleted = true
		main.on_resource_depleted(self)
	return got


func _update_label() -> void:
	if label:
		label.text = "%d" % amount if kind == "wood" else "%s %d" % [rname, amount]


func _process(delta: float) -> void:
	_t += delta
	if visual and not depleted and kind == "wood":
		if _shake > 0.0:
			_shake -= delta
			visual.rotation.z = sin(_t * 60.0) * 0.05
		else:
			visual.rotation.z = 0.0
