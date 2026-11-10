extends Node

# Постоянный хост HTTP API (автолоад BalanceApiHost).
# Живёт всё время работы процесса и переживает reload_current_scene().
# Пока сцена перезагружается (game == null), отвечает 503 + Retry-After
# вместо сброса соединения — клиенты могут ретрайнуть через ~500 мс.

var server := TCPServer.new()
var peers := {}

var game: Node = null      # текущий экземпляр BalanceGame; null во время reload
var bound_port := 0
var listen_error := OK

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func start(port: int) -> int:
	if server.is_listening():
		return bound_port
	listen_error = server.listen(port)
	bound_port = port
	return listen_error

func stop() -> void:
	server.stop()

func _process(_delta: float) -> void:
	if game == null:
		_poll_reloading()
	else:
		game._poll_api()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop()
		get_tree().quit()

func _poll_reloading() -> void:
	while server.is_connection_available():
		var p: StreamPeerTCP = server.take_connection()
		p.poll()
		peers[p] = ""
	for p: StreamPeerTCP in peers.keys():
		p.poll()
		var res: Array = p.get_partial_data(65536)
		if res.size() == 2 and res[1] is PackedByteArray and res[1].size() > 0:
			peers[p] += (res[1] as PackedByteArray).get_string_from_utf8()
		var buf: String = peers[p]
		if buf.find("\r\n\r\n") == -1:
			if p.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				peers.erase(p)
			continue
		var body := "{\"error\":\"scene reloading\",\"retry_after_ms\":500}"
		var response := "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 1\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.length(), body]
		p.put_data(response.to_utf8_buffer())
		p.disconnect_from_host()
		peers.erase(p)
