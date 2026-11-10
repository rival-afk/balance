extends Node2D

## Balance Game — менеджер параллельных игр (лейнов) + HTTP API.
## Архитектура как у rocket-landing: каждая игра — свой SubViewport + World2D,
## сетка ячеек 1×1 … 4×N, solo-режим с полным HUD, swarm — кадр + «GAME N» + счёт.
## API-хост (BalanceApiHost) — автолоад, переживает reload сцены.
## Порт по умолчанию 8787; --port=NNN, переменная BALANCE_PORT, --spawn=N,
## --quit-if-port-busy.

const VERSION := "1.0.0"
const SV_W := 960.0
const SV_H := 540.0
const HUD_HZ_MS := 100
const SAVE_HZ_MS := 5000
const MAX_TIME_SCALE := 20.0
const BEST_PATH := "user://balance_best.json"
const LANE_COLORS := [
	Color(0.910, 0.765, 0.227),
	Color(0.36, 0.78, 0.96),
	Color(0.36, 0.86, 0.55),
	Color(0.86, 0.45, 0.72),
	Color(0.95, 0.62, 0.25),
	Color(0.58, 0.62, 0.98),
	Color(0.35, 0.90, 0.80),
	Color(0.98, 0.42, 0.42),
]

var lanes: Array = []
var next_lane_id := 0
var best := 0.0
var _best_dirty := false
var _physics_tick := 0
var _api_host: Node
var _grid: GridContainer
var _last_save_msec := 0
var _hud_last_msec := 0
var _spawn_extra := 0
var _assist_default := -1  ## -1 = не переопределять, 0..4 — заданный при запуске
var _hud := {}
var _shot_path := ""
var _shot_deadline := 0

func _ready() -> void:
	var port := 8787
	var quit_if_port_busy := false
	var env_port := OS.get_environment("BALANCE_PORT")
	if env_port != "" and env_port.is_valid_int():
		port = int(env_port)
	var user_args := OS.get_cmdline_user_args()
	for arg in user_args + OS.get_cmdline_args():
		if arg.begins_with("--port="):
			port = int(arg.split("=")[1])
		elif arg == "--quit-if-port-busy":
			quit_if_port_busy = true
		elif arg.begins_with("--spawn="):
			_spawn_extra = int(arg.split("=")[1])
		elif arg.begins_with("--assist="):
			_assist_default = int(arg.split("=")[1])
	for i in user_args.size():
		if user_args[i] == "--shot" and i + 1 < user_args.size():
			_shot_path = user_args[i + 1]
			_shot_deadline = Time.get_ticks_msec() + 1500

	best = _load_best()

	var grid_layer := CanvasLayer.new()
	grid_layer.layer = 10
	add_child(grid_layer)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.offset_left = 4
	margin.offset_top = 4
	margin.offset_right = -4
	margin.offset_bottom = -4
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid_layer.add_child(margin)
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_grid)

	_hud = _bind_hud()
	if _hud.has("root") and _hud["root"]:
		_hud["root"].layer = 20

	_create_lane()
	for i in _spawn_extra:
		_create_lane()
	if _assist_default >= 0:
		for lane in lanes:
			lane["node"].set_assist(_assist_default)
	_relayout_grid()

	_api_host = get_tree().root.get_node_or_null("BalanceApiHost")
	if _api_host != null:
		_api_host.game = self
		var err: int = _api_host.start(port)
		if err != OK:
			print("Balance API: порт %d занят (код %d) — API отключено" % [port, err])
			if quit_if_port_busy:
				get_tree().quit()
				return
		else:
			print("Balance %s" % VERSION)
			print("Balance API: http://127.0.0.1:%d" % port)

func _exit_tree() -> void:
	if _api_host != null:
		_api_host.game = null
	_flush_best(true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_flush_best(true)
		get_tree().quit()

func _flush_best(force := false) -> void:
	if not _best_dirty and not force:
		return
	var f := FileAccess.open(BEST_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"best": best}))
	_best_dirty = false

func _load_best() -> float:
	if FileAccess.file_exists(BEST_PATH):
		var f := FileAccess.open(BEST_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			if data is Dictionary:
				return float(data.get("best", 0.0))
	return 0.0

func _grid_cols(n: int) -> int:
	if n <= 1:
		return 1
	if n <= 4:
		return 2
	if n <= 9:
		return 3
	return 4

func _relayout_grid() -> void:
	_grid.columns = _grid_cols(lanes.size())
	var show_hud := lanes.size() == 1
	for lane in lanes:
		var cell: Control = lane["cell"]
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if _hud.has("root") and _hud["root"]:
		_hud["root"].visible = show_hud

func _create_lane() -> Dictionary:
	return _create_lane_with_id(next_lane_id)

func _create_lane_with_id(id: int) -> Dictionary:
	if id == next_lane_id:
		next_lane_id += 1
	var color: Color = LANE_COLORS[id % LANE_COLORS.size()]

	var cell := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.08, 0.92)
	sb.set_corner_radius_all(8)
	sb.border_color = color
	sb.set_border_width_all(2)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 3
	sb.content_margin_bottom = 5
	cell.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	cell.add_child(vbox)

	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = "GAME %d" % id
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", color)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var status := Label.new()
	status.add_theme_font_size_override("font_size", 10)
	status.add_theme_color_override("font_color", color)
	status.text = "0 · ×1.0"
	head.add_child(title)
	head.add_child(status)
	vbox.add_child(head)

	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	svc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(svc)

	var sv := SubViewport.new()
	sv.size = Vector2(SV_W, SV_H)
	sv.world_2d = World2D.new()
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.physics_object_picking = false
	svc.add_child(sv)

	var lane_scene: PackedScene = load("res://lane.tscn")
	var lane_node = lane_scene.instantiate()
	lane_node.lane_id = id
	lane_node.lane_idx = id
	lane_node.manager = self
	sv.add_child(lane_node)

	_grid.add_child(cell)

	var lane := {
		"id": id,
		"cell": cell,
		"viewport": sv,
		"node": lane_node,
		"status": status,
	}
	lanes.append(lane)
	_relayout_grid()
	return lane

func _lane_by_id(id: int) -> Variant:
	for lane in lanes:
		if lane["id"] == id:
			return lane
	return null

func _delete_lane(id: int) -> bool:
	var lane = _lane_by_id(id)
	if lane == null:
		return false
	lane["cell"].queue_free()
	lanes.erase(lane)
	_relayout_grid()
	return true

func _respawn_lane(id: int) -> bool:
	var lane = _lane_by_id(id)
	if lane == null:
		return false
	lane["cell"].queue_free()
	lanes.erase(lane)
	_create_lane_with_id(id)
	return true

func _physics_process(delta: float) -> void:
	_physics_tick += 1
	for lane in lanes:
		var node = lane["node"]
		if node.score > best:
			best = node.score
			_best_dirty = true
	var now := Time.get_ticks_msec()
	if now - _last_save_msec >= SAVE_HZ_MS:
		_last_save_msec = now
		_flush_best(false)

func _process(_delta: float) -> void:
	if _shot_deadline > 0 and Time.get_ticks_msec() >= _shot_deadline:
		var img := get_viewport().get_texture().get_image()
		if img != null:
			var err := img.save_png(_shot_path)
			print("shot saved to %s (err %d)" % [_shot_path, err])
		else:
			print("shot failed: viewport texture unavailable")
		get_tree().quit()
		return
	var now := Time.get_ticks_msec()
	if now - _hud_last_msec >= HUD_HZ_MS:
		_hud_last_msec = now
		_update_hud()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_UP:
			_bump_assist(1)
		elif event.keycode == KEY_DOWN:
			_bump_assist(-1)
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()

func _bump_assist(delta: int) -> void:
	if lanes.is_empty():
		return
	var cur: int = lanes[0]["node"].assist_level
	var lvl := clampi(cur + delta, 0, 4)
	for lane in lanes:
		lane["node"].set_assist(lvl)

func _bind_hud() -> Dictionary:
	var hud := {}
	for path in ["ScoreValue", "BestLabel", "MultLabel", "TiltLabel", "PerfectLabel", "Gauge", "TelemetryLabel", "AssistLabel"]:
		hud[path] = find_child(path, true, false)
	hud["root"] = get_node_or_null("HUD")
	return hud

func _update_hud() -> void:
	if lanes.is_empty():
		return
	for lane in lanes:
		var st: Dictionary = lane["node"].get_state()
		lane["status"].text = "%d · ×%.1f" % [int(st["score"]), st["multiplier"]]
	var main_node = lanes[0]["node"]
	var s: Dictionary = main_node.get_state()
	if _hud.has("ScoreValue") and _hud["ScoreValue"]:
		_hud["ScoreValue"].text = "%d" % int(s["score"])
	if _hud.has("BestLabel") and _hud["BestLabel"]:
		_hud["BestLabel"].text = "Рекорд  %d" % int(maxf(best, s["score"]))
	if _hud.has("MultLabel") and _hud["MultLabel"]:
		_hud["MultLabel"].text = "Множитель  ×%.1f" % s["multiplier"]
	if _hud.has("TiltLabel") and _hud["TiltLabel"]:
		_hud["TiltLabel"].text = "Наклон  %.0f°  ·  вертикаль %.0f%%" % [s["tilt_deg"], s["verticality"] * 100.0]
	if _hud.has("PerfectLabel") and _hud["PerfectLabel"]:
		var perfect: bool = s["verticality"] > 0.90
		_hud["PerfectLabel"].text = "идеально" if perfect else ""
	if _hud.has("Gauge") and _hud["Gauge"]:
		var mat: ShaderMaterial = _hud["Gauge"].material
		if mat:
			mat.set_shader_parameter("verticality", s["verticality"])
	if _hud.has("AssistLabel") and _hud["AssistLabel"]:
		_hud["AssistLabel"].text = "Помощь  %s" % s["assist_name"]

func _lane_state(lane) -> Dictionary:
	var node = lane["node"]
	var s: Dictionary = node.get_state()
	s["best"] = best
	s["time_scale"] = Engine.time_scale
	return s

func _all_state() -> Dictionary:
	var all := []
	for lane in lanes:
		all.append(_lane_state(lane))
	return {"best": best, "time_scale": Engine.time_scale, "lanes": all}

func _resp(code: int, payload) -> String:
	var body: String = JSON.stringify(payload)
	var reason := "OK" if code == 200 else ("Not Found" if code == 404 else "Bad Request")
	return "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [code, reason, body.length(), body]

func _parse_query(q: String) -> Dictionary:
	var out := {}
	for pair in q.split("&"):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2:
			out[kv[0].uri_decode()] = kv[1].uri_decode()
		else:
			out[kv[0].uri_decode()] = ""
	return out

func _handle_request(head: String, body: String) -> String:
	var first_line := head.split("\r\n")[0]
	var parts := first_line.split(" ")
	if parts.size() < 3:
		return _resp(400, {"error": "bad request line"})
	var method := parts[0].to_upper()
	var target := parts[1]

	var path := target
	var query := {}
	var qpos := target.find("?")
	if qpos != -1:
		path = target.substr(0, qpos)
		query = _parse_query(target.substr(qpos + 1))

	var json_body: Variant = null
	var trimmed := body.strip_edges()
	if trimmed != "":
		var json := JSON.new()
		if json.parse(trimmed) != OK:
			return _resp(400, {"error": "invalid JSON object expected"})
		if not (json.data is Dictionary):
			return _resp(400, {"error": "invalid JSON object expected"})
		json_body = json.data

	match method:
		"GET":
			match path:
				"/":
					return _resp(200, {
						"name": "balance",
						"version": VERSION,
						"docs": "api_docs.md",
						"endpoints": ["/health", "/state", "/state?lane=N", "/control", "/speed", "/spawn", "/respawn", "/reset", "/lane"],
					})
				"/health":
					return _resp(200, {"ok": true, "version": VERSION, "time_scale": Engine.time_scale, "lanes": lanes.size(), "best": best})
				"/state":
					if query.has("lane"):
						var lane = _lane_by_id(int(query["lane"]))
						if lane == null:
							return _resp(404, {"error": "lane not found"})
						return _resp(200, _lane_state(lane))
					return _resp(200, _all_state())
				_:
					return _resp(404, {"error": "not found"})
		"POST":
			match path:
				"/control":
					var b: Dictionary = json_body if json_body != null else {}
					var lane = _lane_by_id(int(b.get("lane", 0)))
					if lane == null:
						return _resp(404, {"error": "lane not found"})
					var node = lane["node"]
					if b.has("direction"):
						node.set_api_direction(float(b["direction"]))
					return _resp(200, _lane_state(lane))
				"/assist":
					var b: Dictionary = json_body if json_body != null else {}
					var lvl := int(b.get("level", 1))
					if b.has("lane"):
						var lane = _lane_by_id(int(b["lane"]))
						if lane == null:
							return _resp(404, {"error": "lane not found"})
						lane["node"].set_assist(lvl)
						return _resp(200, {"ok": true, "lane": int(b["lane"]), "assist": clampi(lvl, 0, 4)})
					for lane in lanes:
						lane["node"].set_assist(lvl)
					return _resp(200, {"ok": true, "lanes": lanes.size(), "assist": clampi(lvl, 0, 4)})
				"/speed":
					var b: Dictionary = json_body if json_body != null else {}
					var s := clampf(float(b.get("scale", 1.0)), 0.05, MAX_TIME_SCALE)
					Engine.time_scale = s
					return _resp(200, {"time_scale": s})
				"/spawn":
					var lane := _spawn_lane()
					return _resp(200, {"lane": lane["id"], "lanes": lanes.size()})
				"/respawn":
					var b: Dictionary = json_body if json_body != null else {}
					if not b.has("lane"):
						return _resp(400, {"error": "lane required"})
					if not _respawn_lane(int(b["lane"])):
						return _resp(404, {"error": "lane not found"})
					return _resp(200, {"ok": true, "lane": int(b["lane"])})
				"/reset":
					var b: Dictionary = json_body if json_body != null else {}
					if b.has("lane"):
						if not _respawn_lane(int(b["lane"])):
							return _resp(404, {"error": "lane not found"})
						return _resp(200, {"ok": true, "lane": int(b["lane"])})
					get_tree().reload_current_scene()
					return _resp(200, {"ok": true, "reloading": true})
				"/lane/delete":
					var b: Dictionary = json_body if json_body != null else {}
					if not b.has("lane"):
						return _resp(400, {"error": "lane required"})
					return _delete_lane_resp(int(b["lane"]))
				_:
					return _resp(404, {"error": "not found"})
		"DELETE":
			match path:
				"/lane":
					if not query.has("lane"):
						return _resp(400, {"error": "lane query parameter required (?lane=N)"})
					return _delete_lane_resp(int(query["lane"]))
				_:
					return _resp(404, {"error": "not found"})
		_:
			return _resp(404, {"error": "not found"})

func _spawn_lane() -> Dictionary:
	return _create_lane()

func _delete_lane_resp(id: int) -> String:
	if lanes.size() <= 1:
		return _resp(400, {"error": "cannot delete the last lane"})
	if not _delete_lane(id):
		return _resp(404, {"error": "lane not found"})
	return _resp(200, {"ok": true, "lane": id, "lanes": lanes.size()})

func _poll_api() -> void:
	if _api_host == null:
		return
	var host: Node = _api_host
	var server: TCPServer = host.server
	if not server.is_listening():
		return
	while server.is_connection_available():
		var p: StreamPeerTCP = server.take_connection()
		p.set_no_delay(true)
		host.peers[p] = ""
	for p: StreamPeerTCP in host.peers.keys():
		p.poll()
		var res: Array = p.get_partial_data(65536)
		if res.size() == 2 and res[1] is PackedByteArray and res[1].size() > 0:
			host.peers[p] += (res[1] as PackedByteArray).get_string_from_utf8()
		var buf: String = host.peers[p]
		var header_end := buf.find("\r\n\r\n")
		if header_end == -1:
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				host.peers.erase(p)
			continue
		var content_length := 0
		for line in buf.substr(0, header_end).split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				content_length = int(line.split(":")[1].strip_edges())
		var body_start := header_end + 4
		if buf.length() < body_start + content_length:
			continue
		var body := buf.substr(body_start)
		var response := _handle_request(buf, body)
		p.put_data(response.to_utf8_buffer())
		p.disconnect_from_host()
		host.peers.erase(p)
