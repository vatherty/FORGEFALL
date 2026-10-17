# scripts/ui/multiplayer_menu.gd
# FORGEFALL — Goal 4 Multiplayer (Worker B: lobby + menu).
# Self-contained multiplayer menu: player name, HOST (map + mode),
# JOIN (LAN browser + direct IP), and a lobby (player list, ready,
# host-only Start, Leave). Emits back_requested / start_match_requested
# for the coordinator to wire into the main menu / Main.
#
# NETMANAGER CONTRACT (Worker A owns NetManager; this menu is defensive):
#  - If a /root/NetManager autoload exists with create_server(port) /
#    create_client(ip, port), the menu delegates peer creation to it.
#    Return values may be int (Error), bool (success), or void — all handled.
#  - If NetManager is absent (or lacks those methods), the menu creates an
#    ENetMultiplayerPeer itself. The menu is FULLY functional standalone.
#  - Either way the peer MUST become the SceneTree multiplayer peer, so the
#    menu's lobby tracks the ground-truth signals peer_connected /
#    peer_disconnected / server_disconnected / connection_failed.
#  - The menu does NOT guess a NetManager.start_match() signature: starting
#    a match is the start_match_requested signal, which the coordinator
#    wires to Main (it owns the map/mode/game startup). The menu's only
#    duties on start: stop LAN broadcast, flag the peer as match-owned
#    (so _exit_tree does NOT close it), emit the signal.
#  - Name/ready exchange uses RPCs on THIS node (_rpc_hello/_rpc_roster/
#    _rpc_set_ready/_rpc_match_starting). RPCs require the menu node at
#    the SAME path on every peer — coordinator: instance it as
#    Main/MultiplayerMenu (or any one consistent path) on host and clients.
#    If paths ever differ, RPCs silently no-op and the lobby still works
#    with "PLAYER <id>" placeholders + peer_connected/disconnected counts.
#
# DISCONNECT SAFETY: server_disconnected / connection_failed / Leave /
# Back all funnel through _leave_to_browse(reason), which closes the peer,
# stops broadcast, clears the roster, and returns to the browse view.
# The peer is NEVER closed on match start or on _exit_tree after start.
#
# SOLO START: host + 0 clients may press START MATCH. Documented,
# deliberate: lets one player sanity-check a hosted match without a
# second device. Real matches want >= 2 players; the button label says
# so when alone.
extends Control

class_name MultiplayerMenu

## Coordinator: show the main menu again (user pressed Back / Esc in browse).
signal back_requested
## Coordinator: start the match with these settings. Fired on the host
## when the host presses START MATCH, and on every client via the
## _rpc_match_starting broadcast. Coordinator must hide/free this menu
## WITHOUT closing the multiplayer peer (menu already flagged it).
signal start_match_requested(map_id: String, mode_id: String, is_host: bool)
## Fired whenever the lobby roster changes (coordinator/HUD can listen).
signal lobby_updated(players: Array)
## Fired on status-line changes (same text as the on-screen status label).
signal status_changed(message: String)

const SETTINGS_PATH := "user://multiplayer.cfg"
const DEFAULT_PORT := 7777
const MAX_PLAYERS := 8  # 1 host + 7 clients
const CONNECT_TIMEOUT_SEC := 5.0
const MAX_NAME_LEN := 16

## Map keys MUST mirror Main.MAPS in scripts/core/main.gd (Main is not a
## class_name, so the menu cannot read it directly — keep in sync).
const MAP_KEYS := ["dustline", "foundry", "outpost", "cinder_city", "tower_defense", "factory"]
## Mode keys: the three MP modes (MP worker). Main._on_mp_start routes
## each to its real start path (co-op TD / PvP TDM + bots / co-op
## Zombies); the registry (GameModeManager) marks all three implemented.
const MODE_KEYS := ["mp_tower_defense", "mp_tdm", "mp_zombies"]
const MODE_LABELS := ["TOWER DEFENSE (CO-OP)", "TEAM DEATHMATCH", "ZOMBIES (CO-OP)"]

const STATE_BROWSE := "browse"
const STATE_LOBBY := "lobby"

var _state: String = STATE_BROWSE
var _is_host := false
var _match_started := false
var _connecting := false
var _connect_deadline_msec := 0
var _player_name := "PLAYER"
## peer id -> {"name": String, "ready": bool}
var _players: Dictionary = {}
var _discovery: LanDiscovery
var _host_id := ""

# --- UI refs (built in code, main_menu.gd style) ---
var _name_edit: LineEdit
var _map_select: OptionButton
var _mode_select: OptionButton
var _host_button: Button
var _server_list: ItemList
var _refresh_button: Button
var _ip_edit: LineEdit
var _port_spin: SpinBox
var _join_button: Button
var _menu_margin: MarginContainer
var _network_tabs: HBoxContainer
var _host_panel: PanelContainer
var _join_panel: PanelContainer
var _browse_panel: Control
var _lobby_panel: Control
var _lobby_list: ItemList
var _lobby_info: Label
var _ready_button: Button
var _start_button: Button
var _leave_button: Button
var _back_button: Button
var _status_label: Label


func _ready() -> void:
	StencilStyle.install_menu(self)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_host_id = "%s-%d" % [str(OS.get_unique_id()), get_instance_id()]
	_discovery = LanDiscovery.new()
	_discovery.name = "LanDiscovery"
	add_child(_discovery)
	_discovery.game_found.connect(_on_game_found)
	_discovery.game_lost.connect(_on_game_lost)
	_build()
	_load_settings()
	_wire_multiplayer_signals()
	_show_browse()
	# Controller (v0.6.1): initial focus so D-pad + Confirm work with
	# no mouse (text fields skipped — focus there pops the keyboard).
	InputBindings.grab_first_focus(self)


func _process(_delta: float) -> void:
	if _connecting and Time.get_ticks_msec() > _connect_deadline_msec:
		_connecting = false
		_set_status("CONNECTION TIMED OUT — CHECK THE IP AND TRY AGAIN")
		_disconnect_peer()
		_update_buttons()


# --- Public query API (tests + coordinator) ---------------------------------

func get_state() -> String:
	return _state


func is_host() -> bool:
	return _is_host


func get_selected_map() -> String:
	if _map_select == null:
		return MAP_KEYS[0]
	return MAP_KEYS[clampi(_map_select.selected, 0, MAP_KEYS.size() - 1)]


func get_selected_mode() -> String:
	if _mode_select == null:
		return MODE_KEYS[0]
	return MODE_KEYS[clampi(_mode_select.selected, 0, MODE_KEYS.size() - 1)]


## Pre-select the mode picker (Main passes the mode the player chose
## in the main menu's MP select). Unknown ids are ignored.
func set_selected_mode(mode_id: String) -> void:
	var idx := MODE_KEYS.find(mode_id)
	if idx >= 0 and _mode_select != null:
		_mode_select.selected = idx
		_save_last_choices()


func get_player_name() -> String:
	return _player_name


## Roster snapshot: [{id, name, ready}, ...] sorted by id (host first: id 1).
func get_players() -> Array:
	var out: Array = []
	var ids := _players.keys()
	ids.sort()
	for pid in ids:
		var p: Dictionary = _players[pid]
		out.append({"id": int(pid), "name": str(p.get("name", "")), "ready": bool(p.get("ready", false))})
	return out


func get_discovered_games() -> Array:
	if _discovery == null:
		return []
	return _discovery.get_discovered()


# --- UI construction (main_menu.gd conventions: StencilStyle + code-built) --

func _build() -> void:
	StencilStyle.cinematic_background(self, "staging", 0.18, false)

	var margin := MarginContainer.new()
	_menu_margin = margin
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", int(size.x * 0.43) if size.x >= 1100 else 32)
	margin.add_theme_constant_override("margin_top", 48)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	root.custom_minimum_size = Vector2.ZERO
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(root)

	StencilStyle.section_header(root, "MULTIPLAYER")

	# --- Player name row ---
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	name_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(name_row)
	var name_label := Label.new()
	StencilStyle.apply_body(name_label, 20, StencilStyle.TEXT, 2)
	name_label.text = "CALLSIGN"
	name_row.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "CALLSIGN (MAX 16)"
	_name_edit.max_length = MAX_NAME_LEN
	_name_edit.text = _player_name
	_name_edit.custom_minimum_size = Vector2(320, 54)
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_name_edit)
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(func(_t: String) -> void: _save_player_name())
	name_row.add_child(_name_edit)

	_network_tabs = HBoxContainer.new()
	root.add_child(_network_tabs)
	for choice in ["HOST GAME", "JOIN GAME"]:
		var tab := Button.new()
		tab.text = choice
		StencilStyle.navigation_button(tab, choice == "HOST GAME")
		tab.pressed.connect(func() -> void:
			_host_panel.visible = choice == "HOST GAME"
			_join_panel.visible = choice == "JOIN GAME"
			for child in _network_tabs.get_children():
				StencilStyle.navigation_button(child, child.text == choice))
		_network_tabs.add_child(tab)
	# --- Browse view: HOST + JOIN panels ---
	_browse_panel = VBoxContainer.new()
	_browse_panel.add_theme_constant_override("separation", 12)
	root.add_child(_browse_panel)
	_build_host_panel(_browse_panel)
	_build_join_panel(_browse_panel)
	_join_panel.visible = false

	# --- Lobby view (hidden until hosted/joined) ---
	_lobby_panel = VBoxContainer.new()
	_lobby_panel.add_theme_constant_override("separation", 12)
	_lobby_panel.visible = false
	root.add_child(_lobby_panel)
	_build_lobby_panel(_lobby_panel)

	# --- Status + Back ---
	_status_label = Label.new()
	StencilStyle.apply_body(_status_label, 18, StencilStyle.TEXT_DIM, 2)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "READY"
	root.add_child(_status_label)

	_back_button = _menu_button("BACK")
	_back_button.pressed.connect(_on_back)
	root.add_child(_back_button)


func _build_host_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	_host_panel = panel
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var head := Label.new()
	StencilStyle.apply_body(head, 22, StencilStyle.ORANGE, 2)
	head.text = "HOST A GAME"
	vb.add_child(head)

	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 12)
	vb.add_child(map_row)
	var map_label := Label.new()
	StencilStyle.apply_body(map_label, 20, StencilStyle.TEXT, 2)
	map_label.text = "MAP"
	map_label.custom_minimum_size = Vector2(90, 0)
	map_row.add_child(map_label)
	_map_select = OptionButton.new()
	for key in MAP_KEYS:
		_map_select.add_item(key.to_upper())
	_map_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(_map_select)
	_map_select.item_selected.connect(func(_i: int) -> void: _save_last_choices())
	map_row.add_child(_map_select)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 12)
	vb.add_child(mode_row)
	var mode_label := Label.new()
	StencilStyle.apply_body(mode_label, 20, StencilStyle.TEXT, 2)
	mode_label.text = "MODE"
	mode_label.custom_minimum_size = Vector2(90, 0)
	mode_row.add_child(mode_label)
	_mode_select = OptionButton.new()
	for label in MODE_LABELS:
		_mode_select.add_item(label)
	_mode_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_button(_mode_select)
	_mode_select.item_selected.connect(func(_i: int) -> void: _save_last_choices())
	mode_row.add_child(_mode_select)

	_host_button = _menu_button("HOST GAME  —  PORT %d" % DEFAULT_PORT)
	StencilStyle.primary_button(_host_button)
	_host_button.pressed.connect(_on_host_pressed)
	vb.add_child(_host_button)


func _build_join_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	_join_panel = panel
	panel.add_theme_stylebox_override("panel", StencilStyle.panel())
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var head := Label.new()
	StencilStyle.apply_body(head, 22, StencilStyle.ORANGE, 2)
	head.text = "JOIN A GAME"
	vb.add_child(head)

	var hint := Label.new()
	StencilStyle.apply_body(hint, 18, StencilStyle.TEXT_DIM, 2)
	hint.text = "LAN GAMES (AUTO-REFRESH) — SELECT ONE, OR ENTER AN IP BELOW"
	vb.add_child(hint)

	_server_list = ItemList.new()
	_server_list.custom_minimum_size = Vector2(0, 150)
	_server_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server_list.select_mode = ItemList.SELECT_SINGLE
	_server_list.item_selected.connect(func(_i: int) -> void: _click())
	vb.add_child(_server_list)

	_refresh_button = _menu_button("REFRESH LAN LIST")
	_refresh_button.custom_minimum_size = Vector2(0, 48)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	vb.add_child(_refresh_button)

	var ip_row := HBoxContainer.new()
	ip_row.add_theme_constant_override("separation", 12)
	vb.add_child(ip_row)
	var ip_label := Label.new()
	StencilStyle.apply_body(ip_label, 20, StencilStyle.TEXT, 2)
	ip_label.text = "DIRECT IP"
	ip_row.add_child(ip_label)
	_ip_edit = LineEdit.new()
	_ip_edit.placeholder_text = "192.168.1.10"
	_ip_edit.custom_minimum_size = Vector2(160, 54)
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.style_lineedit(_ip_edit)
	ip_row.add_child(_ip_edit)
	var port_label := Label.new()
	StencilStyle.apply_body(port_label, 20, StencilStyle.TEXT, 2)
	port_label.text = "PORT"
	ip_row.add_child(port_label)
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1
	_port_spin.max_value = 65535
	_port_spin.step = 1
	_port_spin.value = DEFAULT_PORT
	_port_spin.custom_minimum_size = Vector2(100, 54)
	_port_spin.editable = true
	ip_row.add_child(_port_spin)

	_join_button = _menu_button("JOIN GAME")
	_join_button.pressed.connect(_on_join_pressed)
	vb.add_child(_join_button)


func _build_lobby_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", StencilStyle.panel_accent())
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)

	var head := Label.new()
	StencilStyle.apply_body(head, 22, StencilStyle.ORANGE, 2)
	head.text = "LOBBY"
	vb.add_child(head)

	_lobby_info = Label.new()
	StencilStyle.apply_body(_lobby_info, 18, StencilStyle.TEXT, 2)
	_lobby_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lobby_info.text = ""
	vb.add_child(_lobby_info)

	_lobby_list = ItemList.new()
	_lobby_list.custom_minimum_size = Vector2(0, 150)
	_lobby_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Read-only roster: no focus, no click selection.
	_lobby_list.focus_mode = Control.FOCUS_NONE
	_lobby_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lobby_list.select_mode = ItemList.SELECT_SINGLE
	vb.add_child(_lobby_list)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	vb.add_child(btn_row)
	_ready_button = _menu_button("READY: NO")
	_ready_button.custom_minimum_size = Vector2(0, 56)
	_ready_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ready_button.pressed.connect(_on_ready_pressed)
	btn_row.add_child(_ready_button)
	_start_button = _menu_button("START MATCH")
	_start_button.custom_minimum_size = Vector2(0, 56)
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StencilStyle.primary_button(_start_button)
	_start_button.pressed.connect(_on_start_pressed)
	btn_row.add_child(_start_button)

	_leave_button = _menu_button("LEAVE LOBBY")
	_leave_button.custom_minimum_size = Vector2(0, 56)
	_leave_button.pressed.connect(_on_leave_pressed)
	vb.add_child(_leave_button)


func _menu_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_ALL
	StencilStyle.style_button(b)
	b.add_theme_font_size_override("font_size", 22)
	return b


# --- Settings persistence ---------------------------------------------------

func _save_player_name() -> void:
	_player_name = _sanitize_name(_name_edit.text if _name_edit != null else _player_name)
	if _name_edit != null and _name_edit.text != _player_name:
		_name_edit.text = _player_name
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("player", "name", _player_name)
	cfg.save(SETTINGS_PATH)


func _save_last_choices() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("player", "name", _player_name)
	cfg.set_value("last", "ip", _ip_edit.text if _ip_edit != null else "")
	cfg.set_value("last", "port", int(_port_spin.value) if _port_spin != null else DEFAULT_PORT)
	cfg.set_value("last", "map", get_selected_map())
	cfg.set_value("last", "mode", get_selected_mode())
	cfg.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_player_name = _sanitize_name(str(cfg.get_value("player", "name", "PLAYER")))
	if _name_edit != null:
		_name_edit.text = _player_name
	var last_ip := str(cfg.get_value("last", "ip", ""))
	if _ip_edit != null and last_ip != "":
		_ip_edit.text = last_ip
	if _port_spin != null:
		_port_spin.value = int(cfg.get_value("last", "port", DEFAULT_PORT))
	var last_map := str(cfg.get_value("last", "map", MAP_KEYS[0]))
	var midx := MAP_KEYS.find(last_map)
	if _map_select != null and midx >= 0:
		_map_select.selected = midx
	var last_mode := str(cfg.get_value("last", "mode", MODE_KEYS[0]))
	var moidx := MODE_KEYS.find(last_mode)
	if _mode_select != null and moidx >= 0:
		_mode_select.selected = moidx


func _sanitize_name(raw: String) -> String:
	var n := raw.strip_edges()
	if n == "":
		n = "PLAYER"
	return n.substr(0, MAX_NAME_LEN)


func _on_name_changed(new_text: String) -> void:
	_player_name = _sanitize_name(new_text)
	_save_player_name()
	# A name change mid-lobby re-announces to everyone.
	if _state == STATE_LOBBY:
		if _is_host:
			_add_player(_my_id(), _player_name, _players.get(_my_id(), {}).get("ready", false))
			_broadcast_roster()
		else:
			rpc("_rpc_hello", _player_name)


# --- NetManager resolution --------------------------------------------------

## Our peer id, or 0 when no peer is assigned (browse state). Guards
## get_unique_id(), which logs an error when the peer is null.
func _my_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 0
	return multiplayer.get_unique_id()


## /root/NetManager if Worker A registered it as an autoload; /root/Net as
## a fallback if the autoload was registered under that name instead
## (menu then falls back to direct ENet — fully functional standalone).
func _net_manager() -> Node:
	var nm := get_node_or_null("/root/NetManager")
	if nm != null:
		return nm
	return get_node_or_null("/root/Net")


## Normalise a NetManager create_* return (int Error / bool / void) to Error.
func _result_to_error(r: Variant) -> int:
	if r is int:
		return int(r)
	if r is bool:
		return OK if bool(r) else ERR_CANT_CONNECT
	return OK  # void / null: assume success; multiplayer signals confirm it.


# --- Host / Join ------------------------------------------------------------

func _on_host_pressed() -> void:
	_click()
	if _state != STATE_BROWSE or _connecting:
		return
	_save_player_name()
	_save_last_choices()
	var err := OK
	var net := _net_manager()
	if net != null and net.has_method("create_server"):
		err = _result_to_error(net.call("create_server", DEFAULT_PORT))
	else:
		var peer := ENetMultiplayerPeer.new()
		err = peer.create_server(DEFAULT_PORT, MAX_PLAYERS)
		if err == OK:
			multiplayer.multiplayer_peer = peer
	if err != OK:
		_set_status("FAILED TO HOST (PORT %d BUSY?) — TRY AGAIN" % DEFAULT_PORT)
		_update_buttons()
		return
	_is_host = true
	_enter_lobby()
	_set_status("HOSTING — WAITING FOR PLAYERS (LAN BROWSER + DIRECT IP)")


func _on_join_pressed() -> void:
	_click()
	if _state != STATE_BROWSE or _connecting:
		return
	_save_player_name()
	_save_last_choices()
	var ip := ""
	var port := int(_port_spin.value) if _port_spin != null else DEFAULT_PORT
	var sel: Array = []
	if _server_list != null:
		sel = _server_list.get_selected_items()
	if not sel.is_empty():
		var info: Dictionary = _server_list.get_item_metadata(sel[0])
		ip = str(info.get("ip", ""))
		port = int(info.get("port", DEFAULT_PORT))
	else:
		ip = _ip_edit.text.strip_edges() if _ip_edit != null else ""
	if ip == "":
		_set_status("SELECT A LAN GAME ABOVE, OR ENTER AN IP TO JOIN")
		return
	var err := OK
	var net := _net_manager()
	if net != null and net.has_method("create_client"):
		err = _result_to_error(net.call("create_client", ip, port))
	else:
		var peer := ENetMultiplayerPeer.new()
		err = peer.create_client(ip, port)
		if err == OK:
			multiplayer.multiplayer_peer = peer
	if err != OK:
		_set_status("COULD NOT CONNECT TO %s:%d — CHECK THE IP" % [ip, port])
		_disconnect_peer()
		_update_buttons()
		return
	_connecting = true
	_connect_deadline_msec = Time.get_ticks_msec() + int(CONNECT_TIMEOUT_SEC * 1000)
	_set_status("CONNECTING TO %s:%d …" % [ip, port])
	_update_buttons()


func _on_refresh_pressed() -> void:
	_click()
	_refresh_discovery()


func _refresh_discovery() -> void:
	if _server_list != null:
		_server_list.clear()
	if _discovery == null:
		return
	_discovery.stop_listening()
	if not _discovery.start_listening():
		_set_status("LAN DISCOVERY UNAVAILABLE ON THIS NETWORK — DIRECT IP STILL WORKS")
	else:
		_set_status("SCANNING LAN FOR GAMES …")


# --- Lobby ------------------------------------------------------------------

func _enter_lobby() -> void:
	_state = STATE_LOBBY
	_connecting = false
	_players.clear()
	var my_id := _my_id()
	_add_player(my_id, _player_name, false)
	_show_lobby()
	if _is_host:
		_discovery.stop_listening()
		_discovery.start_broadcasting(_broadcast_info())
		_set_status("HOSTING — WAITING FOR PLAYERS")
	else:
		_discovery.stop_listening()
		# Announce our callsign to the host; host replies with the roster.
		rpc("_rpc_hello", _player_name)
		_set_status("CONNECTED — WAITING FOR HOST TO START")
	_update_buttons()
	_refresh_lobby_list()


func _broadcast_info() -> Dictionary:
	return {
		"host_name": _player_name,
		"map": get_selected_map(),
		"mode": get_selected_mode(),
		"players": _players.size(),
		"max_players": MAX_PLAYERS,
		"port": DEFAULT_PORT,
		"host_id": _host_id,
	}


func _refresh_broadcast_info() -> void:
	if _is_host and _state == STATE_LOBBY and _discovery != null:
		_discovery.update_broadcast_info(_broadcast_info())


func _on_ready_pressed() -> void:
	_click()
	if _state != STATE_LOBBY:
		return
	var my_id := _my_id()
	var cur := bool((_players.get(my_id, {}) as Dictionary).get("ready", false))
	if _is_host:
		_add_player(my_id, _player_name, not cur)
		_broadcast_roster()
	else:
		# Optimistic local flip; host's roster broadcast is authoritative.
		_add_player(my_id, _player_name, not cur)
		rpc("_rpc_set_ready", my_id, not cur)


func _on_start_pressed() -> void:
	_click()
	if _state != STATE_LOBBY or not _is_host:
		return
	if _players.size() < 1:
		return
	# Tell every client to start too (same-path RPC; see header).
	rpc("_rpc_match_starting", get_selected_map(), get_selected_mode())
	_begin_match(get_selected_map(), get_selected_mode())


## Shared start path: host (button) and clients (RPC) converge here.
func _begin_match(map_id: String, mode_id: String) -> void:
	if _match_started:
		return
	_match_started = true
	_connecting = false
	if _discovery != null:
		_discovery.stop_all()  # broadcast MUST stop when the match starts
	_set_status("STARTING MATCH — %s / %s" % [map_id.to_upper(), mode_id.to_upper()])
	start_match_requested.emit(map_id, mode_id, _is_host)


func _on_leave_pressed() -> void:
	_click()
	_leave_to_browse("LEFT LOBBY")


func _on_back() -> void:
	_click()
	if _state == STATE_LOBBY:
		_leave_to_browse("LEFT LOBBY")
		return
	_disconnect_peer()
	if _discovery != null:
		_discovery.stop_all()
	back_requested.emit()


## Leave the lobby (or a failed connect) and return to the browse view.
## Closes the peer, stops discovery broadcast, clears the roster.
func _leave_to_browse(reason: String) -> void:
	_match_started = false
	_connecting = false
	_is_host = false
	_disconnect_peer()
	_players.clear()
	_show_browse()
	_set_status(reason)
	lobby_updated.emit([])


func _disconnect_peer() -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = null


# --- MultiplayerAPI signal handlers (ground truth for the lobby) -----------

func _wire_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)


func _on_peer_connected(id: int) -> void:
	if _state != STATE_LOBBY:
		return
	# Remote name arrives via _rpc_hello; placeholder until then.
	if not _players.has(id):
		_add_player(id, "PLAYER %d" % id, false)
	_set_status("PLAYER %d JOINED" % id)
	_refresh_lobby_list()


func _on_peer_disconnected(id: int) -> void:
	if _state != STATE_LOBBY:
		return
	var name := str((_players.get(id, {}) as Dictionary).get("name", "PLAYER %d" % id))
	_players.erase(id)
	if _is_host:
		_broadcast_roster()  # clients must learn the player left, not just the host
	else:
		_refresh_lobby_list()
	_set_status("%s LEFT" % name)


func _on_connected_to_server() -> void:
	if _state == STATE_LOBBY:
		return  # already in (reconnect edge)
	_is_host = false
	_enter_lobby()


func _on_connection_failed() -> void:
	if _match_started:
		return
	_connecting = false
	_disconnect_peer()
	_set_status("CONNECTION FAILED — HOST UNREACHABLE")
	_update_buttons()


func _on_server_disconnected() -> void:
	if _match_started:
		# Match already running; the game (not this menu) owns the fallout.
		_set_status("HOST DISCONNECTED")
		return
	if _state == STATE_LOBBY:
		_leave_to_browse("HOST LEFT — RETURNED TO MENU")


# --- Name / ready RPCs (require the same node path on every peer) -----------

## Client -> host: "I joined, my callsign is X". Host replies with roster.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	_add_player(sender, _sanitize_name(player_name), false)
	_broadcast_roster()


## Host -> everyone: the authoritative roster (id -> {name, ready}).
@rpc("authority", "call_remote", "reliable")
func _rpc_roster(roster: Dictionary) -> void:
	if multiplayer.is_server():
		return
	_players = roster.duplicate(true)
	_refresh_lobby_list()


## Client -> host: ready toggle. Host applies it and re-broadcasts.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_ready(peer_id: int, ready: bool) -> void:
	if not multiplayer.is_server():
		return
	if _players.has(peer_id):
		var entry: Dictionary = _players[peer_id]
		entry["ready"] = ready
	_broadcast_roster()


## Host -> clients: the match is starting with these settings.
@rpc("authority", "call_remote", "reliable")
func _rpc_match_starting(map_id: String, mode_id: String) -> void:
	if multiplayer.is_server():
		return
	_begin_match(map_id, mode_id)


func _broadcast_roster() -> void:
	if not _is_host:
		return
	_refresh_broadcast_info()
	_refresh_lobby_list()
	rpc("_rpc_roster", _players.duplicate(true))


# --- Roster / list bookkeeping ----------------------------------------------

func _add_player(id: int, player_name: String, ready: bool) -> void:
	_players[id] = {"name": player_name, "ready": ready}
	_refresh_broadcast_info()
	_refresh_lobby_list()


func _refresh_lobby_list() -> void:
	if _lobby_list == null:
		return
	_lobby_list.clear()
	for entry in get_players():
		var label := "%s  %s" % [str(entry["name"]), "[READY]" if bool(entry["ready"]) else "[NOT READY]"]
		if int(entry["id"]) == _my_id():
			label += "  (YOU)"
		if int(entry["id"]) == 1:
			label += "  [HOST]"
		_lobby_list.add_item(label)
	if _lobby_info != null:
		var map_label := get_selected_map().to_upper()
		var mode_label := get_selected_mode().to_upper()
		_lobby_info.text = "%s  /  %s  —  %d / %d PLAYERS" % [map_label, mode_label, _players.size(), MAX_PLAYERS]
	lobby_updated.emit(get_players())
	_update_buttons()


func _update_buttons() -> void:
	if _start_button != null:
		# Host-only. Enabled solo (sanity-check) or with >= 2 players.
		_start_button.visible = _is_host
		_start_button.disabled = not _is_host or _state != STATE_LOBBY or _match_started
		if _is_host and _players.size() < 2:
			_start_button.text = "START MATCH (SOLO — SANITY CHECK)"
		else:
			_start_button.text = "START MATCH"
	if _ready_button != null:
		var my_id := _my_id()
		var ready := bool((_players.get(my_id, {}) as Dictionary).get("ready", false))
		_ready_button.text = "READY: %s" % ("YES" if ready else "NO")
		_ready_button.disabled = _state != STATE_LOBBY or _match_started
	if _host_button != null:
		_host_button.disabled = _state != STATE_BROWSE or _connecting
	if _join_button != null:
		_join_button.disabled = _state != STATE_BROWSE or _connecting


# --- LAN discovery UI ---------------------------------------------------------

func _on_game_found(info: Dictionary) -> void:
	if _server_list == null or _state != STATE_BROWSE:
		return
	var key := str(info.get("key", ""))
	for i in _server_list.item_count:
		var existing: Dictionary = _server_list.get_item_metadata(i)
		if str(existing.get("key", "")) == key:
			_server_list.set_item_text(i, _server_entry_text(info))
			_server_list.set_item_metadata(i, info)
			return
	_server_list.add_item(_server_entry_text(info))
	_server_list.set_item_metadata(_server_list.item_count - 1, info)


func _on_game_lost(host_key: String) -> void:
	if _server_list == null:
		return
	for i in _server_list.item_count:
		var existing: Dictionary = _server_list.get_item_metadata(i)
		if str(existing.get("key", "")) == host_key:
			_server_list.remove_item(i)
			return


func _server_entry_text(info: Dictionary) -> String:
	return "%s  —  %s / %s  (%d/%d)  —  %s:%d" % [
		str(info.get("host_name", "HOST")),
		str(info.get("map", "")).to_upper(),
		str(info.get("mode", "")).to_upper(),
		int(info.get("players", 1)),
		int(info.get("max_players", MAX_PLAYERS)),
		str(info.get("ip", "")),
		int(info.get("port", DEFAULT_PORT)),
	]


# --- View switching / input ---------------------------------------------------

func _show_browse() -> void:
	if _network_tabs != null:
		_network_tabs.visible = true
	_state = STATE_BROWSE
	if _browse_panel != null:
		_browse_panel.visible = true
	if _lobby_panel != null:
		_lobby_panel.visible = false
	_refresh_discovery()
	_update_buttons()
	if _host_button != null:
		_host_button.grab_focus()


func _show_lobby() -> void:
	if _network_tabs != null:
		_network_tabs.visible = false
	if _browse_panel != null:
		_browse_panel.visible = false
	if _lobby_panel != null:
		_lobby_panel.visible = true
	_update_buttons()
	if _ready_button != null:
		_ready_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_back()
		get_viewport().set_input_as_handled()
		return
	# Gamepad B (JOY_BUTTON_B = 1) = back, mirroring Esc.
	if event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		if jb.button_index == JOY_BUTTON_B and jb.pressed and not jb.echo:
			_on_back()
			get_viewport().set_input_as_handled()


func _click() -> void:
	var s := get_node_or_null("/root/Sfx")
	if s != null and s.has_method("play_2d"):
		s.play_2d("ui_click")


func _set_status(msg: String) -> void:
	if _status_label != null:
		_status_label.text = msg
	status_changed.emit(msg)


func _exit_tree() -> void:
	# After match start the peer belongs to the match — never close it here.
	if _match_started:
		return
	if _discovery != null:
		_discovery.stop_all()
	if _state == STATE_LOBBY or _connecting:
		_disconnect_peer()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _menu_margin != null:
		_menu_margin.add_theme_constant_override("margin_right", int(size.x * 0.43) if size.x >= 1100 else 32)
